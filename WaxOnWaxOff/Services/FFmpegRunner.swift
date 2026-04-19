import Foundation

/// Shared ffmpeg process runner used by AudioProcessor and DeliveryProcessor.
/// Extracted to reduce duplication and make the command-building logic testable.
enum FFmpegRunner {

    /// Run an ffmpeg/ffprobe command, discarding stdout/stderr. Throws on non-zero exit.
    static func run(exe: String, args: [String]) async throws {
        let (exitCode, stderr) = try await launch(exe: exe, args: args)
        if exitCode != 0 {
            throw ProcessingError.ffmpegFailed(
                code: exitCode,
                message: stderr.isEmpty ? "Exit code \(exitCode)" : stderr
            )
        }
    }

    /// Run an ffmpeg/ffprobe command and return captured stderr (used for loudnorm JSON, etc.).
    static func capture(exe: String, args: [String]) async throws -> String {
        let (exitCode, stderr) = try await launch(exe: exe, args: args)
        if exitCode != 0 {
            throw ProcessingError.ffmpegFailed(
                code: exitCode,
                message: stderr.isEmpty ? "Exit code \(exitCode)" : stderr
            )
        }
        return stderr
    }

    // MARK: - Loudnorm Parsing

    /// Parse the loudnorm JSON block from ffmpeg stderr output.
    static func parseLoudnormJSON(from output: String) -> [String: String]? {
        guard let braceRange = output.range(of: "{", options: .backwards) else { return nil }

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
              let dict = json as? [String: String] else {
            return nil
        }
        return dict
    }

    // MARK: - Filter Chain Builder

    /// Build the WaxOn prep filter chain string from settings.
    static func waxOnFilterChain(
        dcBlockHz: Int,
        phaseRotation: Bool = true,
        noiseReductionModel: URL? = nil,
        stereo: Bool,
        channel: String = "left",
        sampleRate: Int
    ) -> String {
        var parts: [String] = []

        if let modelURL = noiseReductionModel {
            parts.append("arnndn=m=\(modelURL.path)")
        }

        parts.append("highpass=f=\(dcBlockHz)")

        if !stereo {
            let pan = channel == "left" ? "pan=1c|c0=c0" : "pan=1c|c0=c1"
            parts.append(pan)
        }

        if phaseRotation {
            parts.append("allpass=f=200:t=q:w=0.707")
        }

        parts.append("aresample=\(sampleRate)")

        return parts.joined(separator: ",")
    }

    /// Build the WaxOn brick-wall limiter filter chain string.
    static func limiterFilterChain(
        limitAmp: Double,
        sampleRate: Int,
        attack: Int = 5,
        release: Int = 50
    ) -> String {
        let oversampleSr = sampleRate * 2
        return [
            "aresample=\(oversampleSr)",
            "alimiter=limit=\(limitAmp):attack=\(attack):release=\(release):level=disabled",
            "aresample=\(sampleRate)"
        ].joined(separator: ",")
    }

    // MARK: - Private

    private static func launch(exe: String, args: [String]) async throws -> (Int32, String) {
        guard FileManager.default.fileExists(atPath: exe) else {
            throw ProcessingError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe

                final class DataBox: @unchecked Sendable { var value = Data() }
                let box = DataBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                let timeoutItem = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 900, execute: timeoutItem)

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    readGroup.wait()
                    // SIGTERM from our onCancel handler sets terminationReason to .uncaughtSignal;
                    // no shared flag needed — eliminates the data race.
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let msg = String(data: box.value, encoding: .utf8) ?? ""
                    continuation.resume(returning: (proc.terminationStatus, msg))
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(
                        code: -1,
                        message: "Failed to launch: \(error.localizedDescription)"
                    ))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
