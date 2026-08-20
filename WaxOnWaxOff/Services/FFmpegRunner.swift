@preconcurrency import Foundation

/// Shared ffmpeg/ffprobe process runner used by AudioProcessor and DeliveryProcessor.
enum FFmpegRunner {

    /// Run a command, discarding output. Throws on non-zero exit.
    /// - Parameter fileDuration: source file duration in seconds, used to scale the watchdog
    ///   timeout proportionally: max(300 s, duration × 4). Pass nil to use the 900 s constant.
    static func run(exe: String, args: [String], fileDuration: TimeInterval? = nil) async throws {
        let t = effectiveTimeoutSeconds(for: fileDuration)
        let (exitCode, stderr) = try await launch(exe: exe, args: args, capture: .stderr, timeoutSeconds: t)
        if exitCode != 0 {
            throw ProcessingError.ffmpegFailed(
                code: exitCode,
                message: stderr.isEmpty ? "Exit code \(exitCode)" : stderr
            )
        }
    }

    /// Run a command and return captured stderr. Throws on non-zero exit.
    /// - Parameter fileDuration: see `run(exe:args:fileDuration:)`.
    static func capture(exe: String, args: [String], fileDuration: TimeInterval? = nil) async throws -> String {
        let t = effectiveTimeoutSeconds(for: fileDuration)
        let (exitCode, stderr) = try await launch(exe: exe, args: args, capture: .stderr, timeoutSeconds: t)
        if exitCode != 0 {
            throw ProcessingError.ffmpegFailed(
                code: exitCode,
                message: stderr.isEmpty ? "Exit code \(exitCode)" : stderr
            )
        }
        return stderr
    }

    /// Capture stdout — used for ffprobe, which writes its output to stdout.
    /// - Parameter fileDuration: see `run(exe:args:fileDuration:)`.
    static func captureStdout(exe: String, args: [String], fileDuration: TimeInterval? = nil) async throws -> String {
        let t = effectiveTimeoutSeconds(for: fileDuration)
        let (exitCode, stdout) = try await launch(exe: exe, args: args, capture: .stdout, timeoutSeconds: t)
        if exitCode != 0 {
            throw ProcessingError.ffmpegFailed(
                code: exitCode,
                message: stdout.isEmpty ? "Exit code \(exitCode)" : stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdout
    }

    /// Escape a string for safe use inside an FFmpeg filtergraph value.
    nonisolated static func filterEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'",  with: "\\'")
         .replacingOccurrences(of: ":",  with: "\\:")
         .replacingOccurrences(of: "[",  with: "\\[")
         .replacingOccurrences(of: "]",  with: "\\]")
         .replacingOccurrences(of: ",",  with: "\\,")
         .replacingOccurrences(of: ";",  with: "\\;")
    }

    // MARK: - Loudnorm Parsing

    /// Parse the loudnorm JSON block from ffmpeg stderr. Returns nil if not found or malformed.
    /// Values may arrive as JSON strings (current FFmpeg) or JSON numbers (in case the
    /// upstream output format ever changes); both are normalized to strings.
    nonisolated static func parseLoudnormJSON(from output: String) -> [String: String]? {
        // Anchor on the loudnorm filter's own log prefix so any later stderr
        // chatter that happens to contain `{` (filter parameter dumps,
        // deprecation notices, etc.) can't latch the parser onto the wrong
        // brace. Falls back to the first `{` in stderr if the prefix is absent.
        let searchStart: String.Index
        if let prefixRange = output.range(of: "[Parsed_loudnorm_", options: .backwards) {
            searchStart = prefixRange.upperBound
        } else {
            searchStart = output.startIndex
        }
        guard let braceRange = output.range(of: "{", range: searchStart..<output.endIndex) else { return nil }

        var depth = 0
        var jsonEnd: String.Index?
        outer: for idx in output[braceRange.lowerBound...].indices {
            switch output[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { jsonEnd = idx; break outer }
            default: break
            }
        }

        guard let jsonEnd else { return nil }

        let jsonStr = String(output[braceRange.lowerBound...jsonEnd])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else {
            return nil
        }

        var result: [String: String] = [:]
        for (key, value) in dict {
            if let s = value as? String {
                result[key] = s
            } else if let n = value as? NSNumber {
                result[key] = n.stringValue
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - ebur128 Frame-Metadata Parsing

    /// Whole-file values from an `ebur128=peak=true:metadata=1,ametadata=mode=print:file=-`
    /// pass, taken from the final 100 ms frame's metadata block — the frame
    /// stream carries full-precision values (3 decimals for loudness, linear
    /// amplitude for true peak), unlike the 1-decimal stderr Summary block.
    struct Ebur128Reading: Sendable {
        let integrated: Double   // lavfi.r128.I — LUFS
        let lra: Double          // lavfi.r128.LRA — LU
        let truePeakDB: Double   // 20·log10(lavfi.r128.true_peak) — dBTP, 4× oversampled per BS.1770
    }

    /// Parse the last-seen `lavfi.r128.*` values from an ametadata print stream
    /// (one block per 100 ms frame; the final block holds the whole-file
    /// integrated values, so last occurrence wins). Returns nil if any of the
    /// three keys never appears. A non-positive linear peak (digital silence)
    /// maps to -inf dBTP, matching what loudnorm reports for silent input.
    nonisolated static func parseEbur128FrameMetadata(from output: String) -> Ebur128Reading? {
        var integrated: Double?
        var lra: Double?
        var peakLinear: Double?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("lavfi.r128.I=") {
                integrated = Double(line.dropFirst("lavfi.r128.I=".count)) ?? integrated
            } else if line.hasPrefix("lavfi.r128.LRA=") {
                lra = Double(line.dropFirst("lavfi.r128.LRA=".count)) ?? lra
            } else if line.hasPrefix("lavfi.r128.true_peak=") {
                peakLinear = Double(line.dropFirst("lavfi.r128.true_peak=".count)) ?? peakLinear
            }
        }

        guard let integrated, let lra, let peakLinear else { return nil }
        let truePeakDB = peakLinear > 0 ? 20 * log10(peakLinear) : -Double.infinity
        return Ebur128Reading(integrated: integrated, lra: lra, truePeakDB: truePeakDB)
    }

    // MARK: - Private

    private enum CaptureTarget { case stderr, stdout }

    nonisolated static let processTimeoutSeconds: Int = 900

    /// Effective watchdog timeout for an ffmpeg invocation.
    /// When source duration is known: max(300 s, duration × 4) — five-minute floor, four
    /// times the file length. A 90-minute recording gets a six-hour window; a 10-second
    /// clip gets the five-minute floor. Falls back to `processTimeoutSeconds` (900 s) when nil.
    nonisolated static func effectiveTimeoutSeconds(for fileDuration: TimeInterval?) -> Int {
        // Belt-and-suspenders: guard non-finite and out-of-range values before the
        // Int conversion — Int(Double) traps on overflow for large doubles. Parse
        // sites already validate, but this prevents a crash if a bad value reaches
        // here via any future path. 30 days covers any real podcast file.
        guard let d = fileDuration, d.isFinite, d >= 0, d <= 30 * 24 * 3600 else {
            return processTimeoutSeconds
        }
        return max(300, Int((d * 4.0).rounded()))
    }

    private static func launch(
        exe: String,
        args: [String],
        capture: CaptureTarget,
        timeoutSeconds: Int
    ) async throws -> (Int32, String) {
        guard FileManager.default.fileExists(atPath: exe) else {
            throw ProcessingError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        // Tracks whether *we* sent SIGTERM via the onCancel handler. Set before
        // calling process.terminate() so the terminationHandler can distinguish
        // a deliberate user-cancel from an ffmpeg crash (SIGSEGV, SIGABRT, OOM
        // SIGKILL, etc.). Without this flag, any signal-terminated child would be
        // reported as CancellationError, silently aborting the entire batch.
        let cancelFlag = TimeoutFlag()

        // Set to true only after process.run() returns without throwing. Guards all
        // process.terminate() call sites: both the watchdog and the onCancel handler
        // must be no-ops if the process was never launched, because calling
        // terminate() on an unlaunched Process raises NSInvalidArgumentException.
        let launchFlag = TimeoutFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
                let pipe = Pipe()
                switch capture {
                case .stderr:
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = pipe
                case .stdout:
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                }

                // nonisolated: same treatment as TimeoutFlag below — the box is
                // captured by the pipe-reader closure on the utility queue and by
                // the termination handler, so its last release happens off-task;
                // an implicit MainActor deinit would malloc-abort in macOS 15's
                // isolated-deinit runtime. All state is touched only from those
                // nonisolated queues anyway, per the @unchecked Sendable marking.
                nonisolated final class DataBox: @unchecked Sendable { var value = Data() }
                let box = DataBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                // Watchdog. The flag distinguishes a timeout-triggered SIGTERM
                // from a user-cancel SIGTERM so the terminationHandler can
                // surface a "timed out after Ns" error instead of an opaque
                // CancellationError. Lock guards the read/write across the
                // watchdog queue and the terminationHandler queue.
                let timeoutFlag = TimeoutFlag()
                let timeoutItem = DispatchWorkItem {
                    timeoutFlag.set()
                    if launchFlag.didFire {
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeoutSeconds),
                    execute: timeoutItem
                )

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    readGroup.wait()
                    if timeoutFlag.didFire {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(
                            code: -1,
                            message: "ffmpeg timed out after \(timeoutSeconds) seconds"
                        ))
                        return
                    }
                    // Check cancel flag first — FFmpeg catches SIGTERM and exits
                    // normally with code 255 and reason .exit (not .uncaughtSignal),
                    // so terminationReason alone cannot distinguish a user cancel
                    // from an ordinary non-zero exit.
                    if cancelFlag.didFire {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    // Not cancelled by us. An unexpected signal is an ffmpeg crash
                    // (SIGSEGV, SIGABRT, OOM SIGKILL, etc.) — surface as a real error
                    // so callers don't silently cancel every other in-flight batch job.
                    // Note: on Darwin, terminationStatus holds the signal number when
                    // terminationReason == .uncaughtSignal.
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(
                            code: proc.terminationStatus,
                            message: "ffmpeg crashed (signal \(proc.terminationStatus))"
                        ))
                        return
                    }
                    let msg = String(data: box.value, encoding: .utf8) ?? ""
                    continuation.resume(returning: (proc.terminationStatus, msg))
                }

                do {
                    try process.run()
                    launchFlag.set()
                    // Close the race window: if onCancel fired between the launchFlag
                    // check and launchFlag.set() above, we must terminate the now-running
                    // process ourselves — onCancel saw launchFlag unset and skipped it.
                    if cancelFlag.didFire {
                        process.terminate()
                    }
                } catch {
                    timeoutItem.cancel()
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(
                        code: -1,
                        message: "Failed to launch: \(error.localizedDescription)"
                    ))
                }
            }
        } onCancel: {
            cancelFlag.set()
            if launchFlag.didFire {
                process.terminate()
            }
        }
    }
}

/// Lock-guarded "did the watchdog fire?" flag, safe to read on the termination
/// queue and write on the dispatch queue that runs the timeout work item.
/// The class is `nonisolated` because the dispatch queues that touch it are
/// outside the MainActor default isolation — and the implicit MainActor deinit it
/// would otherwise get malloc-aborts in macOS 15's isolated-deinit runtime when
/// the last release happens off-task (these flags are released on those queues).
private nonisolated final class TimeoutFlag: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var fired = false

    nonisolated func set() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    nonisolated var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
