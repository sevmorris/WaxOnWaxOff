@preconcurrency import Foundation

/// ffmpeg/ffprobe invocations for AudioProcessor and DeliveryProcessor: timeout
/// policy, exit-code handling, and the parsers for what the filters print.
/// Running the process itself is `FFmpegProcess`, which is shared verbatim with
/// the sibling app repos and knows nothing about any of this.
enum FFmpegRunner {

    /// Run a command, discarding output. Throws on non-zero exit.
    /// - Parameter fileDuration: source file duration in seconds, used to scale the watchdog
    ///   timeout proportionally: max(300 s, duration × 4). Pass nil to use the 900 s constant.
    static func run(exe: String, args: [String], fileDuration: TimeInterval? = nil) async throws {
        let t = effectiveTimeoutSeconds(for: fileDuration)
        let (exitCode, stderr) = try await FFmpegProcess.launch(exe: exe, args: args, capture: .stderr, timeoutSeconds: t)
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
        let (exitCode, stderr) = try await FFmpegProcess.launch(exe: exe, args: args, capture: .stderr, timeoutSeconds: t)
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
        let (exitCode, stdout) = try await FFmpegProcess.launch(exe: exe, args: args, capture: .stdout, timeoutSeconds: t)
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

    /// Watchdog ceiling when the source duration is unknown.
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
}
