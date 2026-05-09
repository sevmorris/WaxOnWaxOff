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

    /// Silent or near-silent inputs cause `loudnorm` to emit -inf / inf for
    /// some measurements. Pass 2 rejects those values with "Result too large",
    /// so callers must check before plumbing measurements into the linear-mode
    /// filter string.
    var isFinite: Bool {
        inputI.isFinite && inputTP.isFinite && inputLRA.isFinite &&
            inputThresh.isFinite && targetOffset.isFinite
    }

    private nonisolated static func parseNumber(_ value: Any?) -> Double? {
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
        onPhase: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
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
        let outputStem = "\(stem)-lev\(formatNumber(settings.targetLUFS))LUFS"
        let lufs = formatNumber(settings.targetLUFS)
        let tp = String(format: "%.1f", settings.truePeak)
        let lra = formatNumber(settings.lra)

        onLog?("▶ \(url.lastPathComponent)", .info)
        onLog?("  target: \(lufs) LUFS  |  TP \(tp) dBTP  |  LRA \(lra) LU", .verbose)
        onLog?("  phase rotation: 200 Hz allpass (always applied)", .verbose)
        // Phase 1: Analyze loudness
        onPhase?("Analyzing loudness…")
        try Task.checkCancellation()  // CRITICAL-2
        onLog?("  loudnorm: analyzing…", .verbose)
        let measurements = try await analyzeAudio(ffmpeg: ffmpeg, input: url, settings: settings)
        if let m = measurements {
            onLog?("  measured: \(String(format: "%.1f", m.inputI)) LUFS  |  TP \(String(format: "%.1f", m.inputTP)) dBTP  |  LRA \(String(format: "%.1f", m.inputLRA)) LU", .info)
            onLog?("  offset: \(String(format: "%.2f", m.targetOffset)) dB  |  thresh \(String(format: "%.1f", m.inputThresh)) LUFS", .verbose)
        } else {
            onLog?("⚠ Input is silent or near-silent — loudness normalization skipped.", .info)
        }

        // Phase 2: Render WAV
        onPhase?("Normalizing…")
        try Task.checkCancellation()  // CRITICAL-2
        onLog?("  loudnorm: normalizing…", .verbose)
        onLog?("  limiter: 2× oversample (\(settings.sampleRate * 2) Hz)  |  ceiling \(tp) dBTP  |  attack 5 ms  |  release 50 ms", .verbose)
        let wavTempURL = FileManager.waxonTempDirectory.appendingPathComponent("\(outputStem).\(UUID().uuidString.prefix(8)).wav")
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

        // HIGH-3: ensure wavTempURL is cleaned up on any failure path
        defer { try? FileManager.default.removeItem(at: wavTempURL) }

        var outputURLs: [URL] = []

        if settings.outputMode == .wav || settings.outputMode == .both {
            try? FileManager.default.removeItem(at: wavFinalURL)
            try FileManager.default.moveItem(at: wavTempURL, to: wavFinalURL)
            // wavTempURL is now gone (moved); defer removeItem is a no-op for it
            outputURLs.append(wavFinalURL)
            onLog?("✓ \(wavFinalURL.lastPathComponent)", .info)
            onLog?("  → \(wavFinalURL.path)", .verbose)
        }

        // Phase 3: Encode MP3 (if needed)
        if settings.outputMode == .mp3 || settings.outputMode == .both {
            onPhase?("Encoding MP3…")
            try Task.checkCancellation()  // CRITICAL-2
            let mp3TPCeiling = settings.truePeak - 1.0
            onLog?("  mp3: \(settings.mp3Bitrate)k  |  limiter: 2× oversample  |  ceiling \(String(format: "%.1f", mp3TPCeiling)) dBTP", .verbose)

            let sourceForMP3 = settings.outputMode == .both ? wavFinalURL : wavTempURL
            let mp3TempURL = FileManager.waxonTempDirectory.appendingPathComponent("\(outputStem).\(UUID().uuidString.prefix(8)).mp3")
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
            onLog?("✓ \(mp3FinalURL.lastPathComponent)", .info)
            onLog?("  → \(mp3FinalURL.path)", .verbose)
        }

        return outputURLs
    }

    // MARK: - Private

    /// Whole numbers render without a decimal ("9"), fractions render with one ("9.5").
    /// Used for both display strings and FFmpeg filter parameters — `loudnorm`
    /// accepts either form.
    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    /// Returns nil if the analysis ran but the input was silent / near-silent
    /// (loudnorm reports -inf / inf measurements that pass 2 cannot consume).
    /// Throws only on actual ffmpeg or JSON parsing failures.
    private func analyzeAudio(
        ffmpeg: String,
        input: URL,
        settings: WaxOffSettings
    ) async throws -> LoudnormMeasurements? {
        let lufs = formatNumber(settings.targetLUFS)
        let tp   = String(format: "%.1f", settings.truePeak)
        let lra  = formatNumber(settings.lra)
        // Phase rotation runs first so loudnorm's TP measurement reflects the
        // post-rotation waveform — otherwise the pass-2 gain correction is based
        // on a peak budget that no longer matches the rendered output.
        let filterChain = "allpass=f=200:t=q:w=0.707,loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra):print_format=json"

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", filterChain,
            "-f", "null", "-"
        ]

        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: args)

        guard let dict = FFmpegRunner.parseLoudnormJSON(from: stderr),
              let measurements = LoudnormMeasurements(json: dict.mapValues { $0 as Any }) else {
            throw DeliveryError.analysisFailedNoMeasurements
        }
        return measurements.isFinite ? measurements : nil
    }

    private func renderWAV(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings,
        measurements: LoudnormMeasurements?
    ) async throws {
        // Phase rotation always runs. Loudnorm only runs when measurements
        // are available — silent inputs skip it to avoid pass-2 errors.
        var filterChain = "allpass=f=200:t=q:w=0.707"
        if let m = measurements {
            let lufs = formatNumber(settings.targetLUFS)
            let tp   = String(format: "%.1f", settings.truePeak)
            let lra  = formatNumber(settings.lra)
            filterChain += ",loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra)"
            filterChain += ":measured_I=\(m.inputI)"
            filterChain += ":measured_TP=\(m.inputTP)"
            filterChain += ":measured_LRA=\(m.inputLRA)"
            filterChain += ":measured_thresh=\(m.inputThresh)"
            filterChain += ":offset=\(m.targetOffset)"
            filterChain += ":linear=true"
        }

        // Brick-wall limiter as a safety backstop for inter-sample peaks that
        // loudnorm's linear-mode TP analysis missed. Ceiling matches the user's
        // TP setting; on most material the limiter doesn't engage.
        let limitAmp = pow(10.0, settings.truePeak / 20.0)
        let oversampleSr = settings.sampleRate * 2
        filterChain += ",aresample=\(oversampleSr)"
        filterChain += ",alimiter=limit=\(String(format: "%.6f", limitAmp)):attack=5:release=50:level=disabled"
        filterChain += ",aresample=\(settings.sampleRate)"

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", filterChain,
            "-ar", String(settings.sampleRate),
            "-ac", "2",
            "-c:a", "pcm_s24le",
            "-f", "wav",
            output.path
        ]

        try await FFmpegRunner.run(exe: ffmpeg, args: args)
    }

    private func encodeMP3(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings
    ) async throws {
        // 2× oversample → brick-wall limit → resample back
        // Lossy codecs introduce ~0.5–1.5 dB of inter-sample peak overshoot during decode;
        // limiter sits 1 dB below the user's true-peak target as a margin so the decoded
        // MP3 stays under the same effective ceiling as the WAV output.
        // MP3 always targets 44.1 kHz regardless of the WAV sample rate setting.
        let mp3TP = settings.truePeak - 1.0
        let limitAmp = pow(10.0, mp3TP / 20.0)
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
            "-ac", "2",
            "-f", "mp3",
            output.path
        ]

        try await FFmpegRunner.run(exe: ffmpeg, args: args)
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
