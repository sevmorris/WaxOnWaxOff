import Foundation
import OSLog

private let deliveryProcessorLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "DeliveryProcessor")

// MARK: - Batch types

struct DeliveryJobInput: Sendable {
    let id: UUID
    let url: URL
}

struct DeliveryJobResult: Sendable {
    let id: UUID
    let outputURLs: [URL]
}

struct DeliveryJobFailure: Sendable, Error {
    let id: UUID
    let message: String
}

struct DeliveryBatchRunResult: Sendable {
    let successes: [DeliveryJobResult]
    let failures: [DeliveryJobFailure]
}


// MARK: - DeliveryProcessor

actor DeliveryProcessor {

    func run(
        inputs: [DeliveryJobInput],
        settings: WaxOffSettings,
        onFileStarted: (@Sendable (UUID) -> Void)? = nil,
        onPhase: (@Sendable (UUID, String) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
    ) async throws -> DeliveryBatchRunResult {
        guard !inputs.isEmpty else {
            return DeliveryBatchRunResult(successes: [], failures: [])
        }

        let tools = try await FFmpegManager.shared.ensureTools()
        let lufsTag = formatNumber(settings.targetLUFS)
        let allocator = OutputAllocator { [lufsTag] input in
            "\(input.deletingPathExtension().lastPathComponent)-lev\(lufsTag)LUFS.wav"
        }

        let outcomes: [Result<DeliveryJobResult, DeliveryJobFailure>] = try await runBoundedConcurrent(
            inputs: inputs,
            limit: ProcessingConfig.maxConcurrentJobs
        ) { input in
            do {
                try Task.checkCancellation()
                onFileStarted?(input.id)
                let outputs = try await self.process(
                    url: input.url,
                    settings: settings,
                    tools: tools,
                    allocator: allocator,
                    onPhase: { phase in onPhase?(input.id, phase) },
                    onLog: onLog
                )
                return .success(DeliveryJobResult(id: input.id, outputURLs: outputs))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                onLog?("✗ \(input.url.lastPathComponent): \(message)", .info)
                return .failure(DeliveryJobFailure(id: input.id, message: message))
            }
        }

        var successes: [DeliveryJobResult] = []
        var failures: [DeliveryJobFailure] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let r): successes.append(r)
            case .failure(let f): failures.append(f)
            }
        }
        return DeliveryBatchRunResult(successes: successes, failures: failures)
    }

    func process(
        url: URL,
        settings: WaxOffSettings,
        onPhase: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
    ) async throws -> [URL] {
        let tools = try await FFmpegManager.shared.ensureTools()
        let lufsTag = formatNumber(settings.targetLUFS)
        let allocator = OutputAllocator { [lufsTag] input in
            "\(input.deletingPathExtension().lastPathComponent)-lev\(lufsTag)LUFS.wav"
        }
        return try await process(url: url, settings: settings, tools: tools, allocator: allocator, onPhase: onPhase, onLog: onLog)
    }

    private func process(
        url: URL,
        settings: WaxOffSettings,
        tools: FFmpegManager.Paths,
        allocator: OutputAllocator,
        onPhase: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
    ) async throws -> [URL] {
        let ffmpeg = tools.ffmpeg
        // Probe source duration for proportional ffmpeg timeouts (FFmpegRunner.effectiveTimeoutSeconds).
        let fileDuration = await probeFileDuration(ffprobe: tools.ffprobe, url: url)

        let outputDir = OutputDirectory.waxOffOutputDirectory(for: url, settings: settings) { message in
            onLog?("⚠ \(message)", .info)
        }

        let allocatedURL = allocator.allocate(for: url, in: outputDir)
        let outputStem = allocatedURL.deletingPathExtension().lastPathComponent
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
        let measurements = try await analyzeAudio(ffmpeg: ffmpeg, input: url, settings: settings, fileDuration: fileDuration)
        if let m = measurements {
            onLog?("  \(m.formattedSummary)", .info)
            onLog?(String(format: "  offset: %.2f dB  |  thresh %.1f LUFS", m.targetOffset, m.inputThresh), .verbose)
            if abs(m.targetOffset) > 12.0 {
                onLog?(String(format: "⚠ Large gain change (%+.1f dB) — verify the source level and output before delivery.",
                              m.targetOffset), .info)
            }
            onLog?(String(format: "  Δ %+.1f dB applied  |  %.1f LUFS → %.0f LUFS",
                          m.targetOffset, m.inputI, settings.targetLUFS), .info)
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
            measurements: measurements,
            fileDuration: fileDuration
        )

        guard FileManager.default.fileExists(atPath: wavTempURL.path) else {
            throw DeliveryError.outputNotCreated
        }

        // Ensure wavTempURL is cleaned up on all exit paths — including MP3-only
        // mode (where it is the source for encodeMP3) and WAV+Both mode (where it
        // was already moved to wavFinalURL so removeItem is a benign no-op).
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
                // wavTempURL is covered by the outer defer above.
                try? FileManager.default.removeItem(at: mp3TempURL)
            }

            try await encodeMP3(
                ffmpeg: ffmpeg,
                input: sourceForMP3,
                output: mp3TempURL,
                settings: settings,
                fileDuration: fileDuration
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

    /// Probe the source file duration for proportional ffmpeg timeouts.
    /// Returns nil on any ffprobe error or implausible value; callers fall back to the 900 s constant.
    private func probeFileDuration(ffprobe: String, url: URL) async -> TimeInterval? {
        guard let output = try? await FFmpegRunner.captureStdout(exe: ffprobe, args: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]) else { return nil }
        let str = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(str) else { return nil }
        // Guard against non-finite, negative, or absurd values from corrupt container
        // headers. 30 days is a generous ceiling for any real podcast or long-form file.
        let maxDuration: Double = 30 * 24 * 3600
        guard d.isFinite, d >= 0, d <= maxDuration else {
            deliveryProcessorLogger.warning("Implausible audio duration '\(str, privacy: .public)' from \(url.lastPathComponent, privacy: .public) — ignoring, will use default timeout")
            return nil
        }
        return d
    }

    /// Returns nil if the analysis ran but the input was silent / near-silent
    /// (loudnorm reports -inf / inf measurements that pass 2 cannot consume).
    /// Throws only on actual ffmpeg or JSON parsing failures.
    ///
    /// Sample-rate assumption: pass-1 (this analysis) and pass-2 (renderWAV) both operate
    /// on the source file at its native sample rate — neither resamples before loudnorm.
    /// They match coincidentally (not by explicit coordination). Any future change to
    /// renderWAV that inserts a pre-loudnorm resample MUST add the same resample here to
    /// keep the measured_I / offset values valid for the new rate.
    private func analyzeAudio(
        ffmpeg: String,
        input: URL,
        settings: WaxOffSettings,
        fileDuration: TimeInterval?
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

        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: args, fileDuration: fileDuration)

        guard let dict = FFmpegRunner.parseLoudnormJSON(from: stderr),
              let measurements = LoudnormMeasurements(json: dict.mapValues { $0 as Any }) else {
            // Include a stderr excerpt so future FFmpeg log-format changes are debuggable.
            let excerpt = String(stderr.prefix(500))
            throw DeliveryError.processingFailed(
                excerpt.isEmpty
                    ? "Could not parse loudnorm analysis output — ffmpeg produced no stderr."
                    : "Could not parse loudnorm analysis output. FFmpeg stderr: \(excerpt)"
            )
        }
        return measurements.isFinite ? measurements : nil
    }

    private func renderWAV(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings,
        measurements: LoudnormMeasurements?,
        fileDuration: TimeInterval?
    ) async throws {
        // Phase rotation always runs. Loudnorm only runs when measurements
        // are available — silent inputs skip it to avoid pass-2 errors.
        var filterChain = "allpass=f=200:t=q:w=0.707"
        // NOTE: loudnorm pass-2 runs at the source file's native sample rate — no pre-loudnorm
        // resample in this filter chain. If you add one here, update analyzeAudio to apply the
        // same resample before its pass-1 analysis so measured_I / offset remain valid.
        if let m = measurements {
            filterChain += "," + m.linearPassFilter(
                targetLUFS: settings.targetLUFS,
                truePeakDB: settings.truePeak,
                lra: settings.lra
            )
        }

        // Brick-wall limiter as a safety backstop for inter-sample peaks that
        // loudnorm's linear-mode TP analysis missed. Ceiling matches the user's
        // TP setting; on most material the limiter doesn't engage.
        let limitAmp = FFmpegFilters.limiterCeilingAmplitude(dBFS: settings.truePeak)
        let oversampleSr = settings.sampleRate * 2
        filterChain += ",\(FFmpegFilters.aresample(to: oversampleSr))"
        filterChain += ",alimiter=limit=\(limitAmp):attack=5:release=50:level=disabled"
        filterChain += ",\(FFmpegFilters.aresample(to: settings.sampleRate))"

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", filterChain,
            // Carry container-level metadata (title/artist/album/comment, BWF
            // chunks on WAV→WAV) from the input. FFmpeg's default for filter
            // graphs is to strip global metadata; a podcast delivery workflow
            // usually wants it preserved.
            "-map_metadata", "0",
            "-ar", String(settings.sampleRate),
            "-ac", "2",
            "-c:a", "pcm_s24le",
            "-f", "wav",
            output.path
        ]

        try await FFmpegRunner.run(exe: ffmpeg, args: args, fileDuration: fileDuration)
    }

    private func encodeMP3(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings,
        fileDuration: TimeInterval?
    ) async throws {
        // 2× oversample → brick-wall limit → resample back
        // Lossy codecs introduce ~0.5–1.5 dB of inter-sample peak overshoot during decode;
        // limiter sits 1 dB below the user's true-peak target as a margin so the decoded
        // MP3 stays under the same effective ceiling as the WAV output.
        // MP3 always targets 44.1 kHz regardless of the WAV sample rate setting.
        let mp3TP = settings.truePeak - 1.0
        let limitAmp = FFmpegFilters.limiterCeilingAmplitude(dBFS: mp3TP)
        let mp3SampleRate = 44100
        let oversampleSr = mp3SampleRate * 2
        let preEncodeFilter = [
            FFmpegFilters.aresample(to: oversampleSr),
            "alimiter=limit=\(limitAmp):attack=1:release=20:level=disabled",
            FFmpegFilters.aresample(to: mp3SampleRate)
        ].joined(separator: ",")

        let title = input.deletingPathExtension().lastPathComponent
        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path,
            "-af", preEncodeFilter,
            "-c:a", "libmp3lame",
            "-b:a", "\(settings.mp3Bitrate)k",
            "-ar", String(mp3SampleRate),
            "-ac", "2",
            // Pull artist/album/etc through from the source, then override the
            // title so it tracks the filename the user is delivering (the
            // source's "title" tag is often a stale working name).
            "-map_metadata", "0",
            "-metadata", "title=\(FFmpegFilters.metadataValue(title))",
            "-f", "mp3",
            output.path
        ]

        try await FFmpegRunner.run(exe: ffmpeg, args: args, fileDuration: fileDuration)
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
