import Foundation

// MARK: - Loudnorm Measurements

struct LoudnormMeasurements: Sendable {
    var inputI: Double
    var inputTP: Double
    var inputLRA: Double
    var inputThresh: Double
    var targetOffset: Double

    nonisolated init?(json: [String: Any]) {
        guard let inputI = Self.parseNumber(json["input_i"]),
              let inputTP = Self.parseNumber(json["input_tp"]),
              let inputLRA = Self.parseNumber(json["input_lra"]),
              let inputThresh = Self.parseNumber(json["input_thresh"]),
              let targetOffset = Self.parseNumber(json["target_offset"])
        else { return nil }
        self.inputI = inputI
        self.inputTP = inputTP
        self.inputLRA = inputLRA
        self.inputThresh = inputThresh
        self.targetOffset = targetOffset
    }

    private static func parseNumber(_ value: Any?) -> Double? {
        if let num = value as? Double { return num }
        if let str = value as? String { return Double(str) }
        return nil
    }
}

// MARK: - DeliveryProcessor

actor DeliveryProcessor {

    func process(
        url: URL,
        settings: WaxOffSettings,
        onPhase: (@Sendable (String) -> Void)? = nil
    ) async throws -> [URL] {
        let paths = try await FFmpegManager.shared.ensureTools()
        let ffmpeg = paths.ffmpeg

        let outputDir: URL
        if let customPath = settings.outputDirectoryPath {
            outputDir = URL(fileURLWithPath: customPath)
        } else {
            outputDir = url.deletingLastPathComponent()
        }

        let stem = url.deletingPathExtension().lastPathComponent
        let outputStem = "\(stem)-lev-\(lufsString(settings.targetLUFS))LUFS"

        // Phase 1: Analyze loudness
        onPhase?("Analyzing loudness…")
        let measurements = try await analyzeAudio(ffmpeg: ffmpeg, input: url, settings: settings)

        // Phase 2: Render WAV
        onPhase?("Normalizing…")
        let wavTempURL = outputDir.appendingPathComponent(".\(outputStem).part.\(UUID().uuidString.prefix(8)).wav")
        let wavFinalURL = outputDir.appendingPathComponent("\(outputStem).wav")

        try await renderWAV(
            ffmpeg: ffmpeg,
            input: url,
            output: wavTempURL,
            settings: settings,
            measurements: measurements
        )

        guard FileManager.default.fileExists(atPath: wavTempURL.path) else {
            throw DeliveryError.outputNotCreated
        }

        var outputURLs: [URL] = []

        if settings.outputMode == .wav || settings.outputMode == .both {
            try? FileManager.default.removeItem(at: wavFinalURL)
            try FileManager.default.moveItem(at: wavTempURL, to: wavFinalURL)
            outputURLs.append(wavFinalURL)
        }

        // Phase 3: Encode MP3 (if needed)
        if settings.outputMode == .mp3 || settings.outputMode == .both {
            onPhase?("Encoding MP3…")

            let sourceForMP3 = settings.outputMode == .both ? wavFinalURL : wavTempURL
            let mp3TempURL = outputDir.appendingPathComponent(".\(outputStem).part.\(UUID().uuidString.prefix(8)).mp3")
            let mp3FinalURL = outputDir.appendingPathComponent("\(outputStem).mp3")

            defer {
                if settings.outputMode == .mp3 {
                    try? FileManager.default.removeItem(at: wavTempURL)
                }
                try? FileManager.default.removeItem(at: mp3TempURL)
            }

            try await encodeMP3(
                ffmpeg: ffmpeg,
                input: sourceForMP3,
                output: mp3TempURL,
                settings: settings
            )

            guard FileManager.default.fileExists(atPath: mp3TempURL.path) else {
                throw DeliveryError.encodingFailed("MP3 file was not created")
            }

            try? FileManager.default.removeItem(at: mp3FinalURL)
            try FileManager.default.moveItem(at: mp3TempURL, to: mp3FinalURL)
            outputURLs.append(mp3FinalURL)
        }

        return outputURLs
    }

    // MARK: - Private

    private func lufsString(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private func analyzeAudio(
        ffmpeg: String,
        input: URL,
        settings: WaxOffSettings
    ) async throws -> LoudnormMeasurements {
        let lufs = lufsString(settings.targetLUFS)
        let tp   = String(format: "%.1f", settings.truePeak)
        let lra  = String(format: "%.0f", settings.lra)
        var filterChain = settings.phaseRotationEnabled ? "allpass=f=150," : ""
        filterChain += "loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra):print_format=json"

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", filterChain,
            "-f", "null", "-"
        ]

        let (_, stderr) = try await runFFmpeg(path: ffmpeg, arguments: args)

        guard let measurements = parseLoudnormJSON(from: stderr) else {
            throw DeliveryError.analysisFailedNoMeasurements
        }
        return measurements
    }

    private func renderWAV(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings,
        measurements: LoudnormMeasurements
    ) async throws {
        let lufs = lufsString(settings.targetLUFS)
        let tp   = String(format: "%.1f", settings.truePeak)
        let lra  = String(format: "%.0f", settings.lra)
        var filterChain = settings.phaseRotationEnabled ? "allpass=f=150," : ""
        filterChain += "loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra)"
        filterChain += ":measured_I=\(measurements.inputI)"
        filterChain += ":measured_TP=\(measurements.inputTP)"
        filterChain += ":measured_LRA=\(measurements.inputLRA)"
        filterChain += ":measured_thresh=\(measurements.inputThresh)"
        filterChain += ":offset=\(measurements.targetOffset)"
        filterChain += ":linear=true"

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", filterChain,
            "-ar", String(settings.sampleRate),
            "-c:a", "pcm_s24le",
            "-f", "wav",
            output.path
        ]

        let (exitCode, stderr) = try await runFFmpeg(path: ffmpeg, arguments: args)
        if exitCode != 0 {
            throw DeliveryError.processingFailed(String(stderr.suffix(500)))
        }
    }

    private func encodeMP3(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings
    ) async throws {
        // 2× oversample → -2 dBTP brick-wall limit → resample back
        // Lossy codecs can introduce +0.1–1.5 dB inter-sample peaks; this prevents decode clipping.
        // MP3 always targets 44.1 kHz regardless of the WAV sample rate setting.
        let limitAmp = pow(10.0, -2.0 / 20.0)
        let mp3SampleRate = 44100
        let oversampleSr = mp3SampleRate * 2
        let preEncodeFilter = [
            "aresample=\(oversampleSr)",
            "alimiter=limit=\(String(format: "%.6f", limitAmp)):attack=1:release=20:level=disabled",
            "aresample=\(mp3SampleRate)"
        ].joined(separator: ",")

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", preEncodeFilter,
            "-c:a", "libmp3lame",
            "-b:a", "\(settings.mp3Bitrate)k",
            "-ar", String(mp3SampleRate),
            "-f", "mp3",
            output.path
        ]

        let (exitCode, stderr) = try await runFFmpeg(path: ffmpeg, arguments: args)
        if exitCode != 0 {
            throw DeliveryError.encodingFailed(String(stderr.suffix(500)))
        }
    }

    private nonisolated func runFFmpeg(path: String, arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        final class DataBox: @unchecked Sendable { var value = Data() }
        let box = DataBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                process.terminationHandler = { proc in
                    readGroup.wait()
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let stderrString = String(data: box.value, encoding: .utf8) ?? ""
                    continuation.resume(returning: (proc.terminationStatus, stderrString))
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private nonisolated func parseLoudnormJSON(from stderr: String) -> LoudnormMeasurements? {
        guard let braceRange = stderr.range(of: "{", options: .backwards) else { return nil }

        var depth = 0
        var jsonEnd: String.Index?
        outer: for idx in stderr[braceRange.lowerBound...].indices {
            switch stderr[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { jsonEnd = idx; break outer }
            default: break
            }
        }

        guard let jsonEnd else { return nil }

        let jsonString = String(stderr[braceRange.lowerBound...jsonEnd])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return LoudnormMeasurements(json: json)
    }
}

// MARK: - Errors

enum DeliveryError: Error, LocalizedError {
    case analysisFailedNoMeasurements
    case outputNotCreated
    case processingFailed(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .analysisFailedNoMeasurements:
            return "Failed to analyze audio — no loudness measurements obtained."
        case .outputNotCreated:
            return "Output file was not created."
        case .processingFailed(let msg):
            return "Processing failed: \(msg)"
        case .encodingFailed(let msg):
            return "MP3 encoding failed: \(msg)"
        }
    }
}
