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
    /// Non-nil when the WAV rendered but MP3 encoding failed in `.both` mode.
    /// Callers should show the WAV as delivered and surface this message in the log.
    let mp3FailureMessage: String?

    init(id: UUID, outputURLs: [URL], mp3FailureMessage: String? = nil) {
        self.id = id
        self.outputURLs = outputURLs
        self.mp3FailureMessage = mp3FailureMessage
    }
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

/// A deferred, advisory verification of one delivered output. Yielded to the
/// verification pool when its file completes and drained concurrently with
/// the rest of the batch — in the pool's own slots, never a delivery slot.
/// Never throws — verification is logging only.
typealias DeferredVerification = @Sendable () async -> Void

actor DeliveryProcessor {

    func run(
        inputs: [DeliveryJobInput],
        settings: WaxOffSettings,
        onFileStarted: (@Sendable (UUID) -> Void)? = nil,
        onFileCompleted: (@Sendable (DeliveryJobResult) -> Void)? = nil,
        onFileFailed: (@Sendable (DeliveryJobFailure) -> Void)? = nil,
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

        // Verifications flow from delivery jobs into an independent bounded
        // pool that drains them concurrently with delivery. The pool is sized
        // by verificationConcurrency and never shares a slot with delivery in
        // either direction: delivery fills its own runBoundedConcurrent limit,
        // and the drain runs in a sibling child task with its own bound. A
        // file's row completes at file-written; its verification lines trail,
        // possibly interleaved with other files' delivery; run() does not
        // return until both children finish, so the batch is only reported
        // complete once every verification line is in.
        let (verificationStream, verificationSink) = AsyncStream<DeferredVerification>.makeStream()

        enum Child: Sendable {
            case outcomes([Result<DeliveryJobResult, DeliveryJobFailure>])
            case drained
        }

        var outcomes: [Result<DeliveryJobResult, DeliveryJobFailure>] = []
        try await withThrowingTaskGroup(of: Child.self) { group in
            group.addTask {
                // Ensure the drain's stream always terminates, including when
                // delivery throws (cancellation) — otherwise the sibling child
                // would wait on the stream forever.
                defer { verificationSink.finish() }
                let outcomes = try await runBoundedConcurrent(
                    inputs: inputs,
                    limit: ProcessingConfig.deliveryConcurrency
                ) { input -> Result<DeliveryJobResult, DeliveryJobFailure> in
                    do {
                        try Task.checkCancellation()
                        onFileStarted?(input.id)
                        let (outputs, mp3Fail, verifications) = try await self.process(
                            url: input.url,
                            settings: settings,
                            tools: tools,
                            allocator: allocator,
                            onPhase: { phase in onPhase?(input.id, phase) },
                            onLog: onLog
                        )
                        let result = DeliveryJobResult(id: input.id, outputURLs: outputs, mp3FailureMessage: mp3Fail)
                        // Completion fires at file-written; this file's
                        // verifications enter the pool strictly afterwards.
                        onFileCompleted?(result)
                        for verification in verifications {
                            verificationSink.yield(verification)
                        }
                        return .success(result)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        onLog?("✗ \(input.url.lastPathComponent): \(message)", .info)
                        let failure = DeliveryJobFailure(id: input.id, message: message)
                        onFileFailed?(failure)
                        return .failure(failure)
                    }
                }
                return .outcomes(outcomes)
            }
            group.addTask {
                try await Self.drainVerifications(
                    verificationStream,
                    poolSize: ProcessingConfig.verificationConcurrency
                )
                return .drained
            }

            for try await child in group {
                if case .outcomes(let o) = child { outcomes = o }
            }
        }

        // Preserve cancel semantics: a cancellation that lands after the last
        // delivery and drain complete must still surface as CancellationError,
        // not as a normal batch result.
        try Task.checkCancellation()

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

    /// Runs verifications from `stream` with at most `poolSize` in flight.
    /// Verifications never throw; the only throw path is cancellation, which
    /// stops un-started work at the checkCancellation gate while FFmpegRunner
    /// SIGTERMs any pass already in flight.
    private static func drainVerifications(
        _ stream: AsyncStream<DeferredVerification>,
        poolSize: Int
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            for await verification in stream {
                if active >= poolSize {
                    try await group.next()
                    active -= 1
                }
                group.addTask {
                    try Task.checkCancellation()
                    await verification()
                }
                active += 1
            }
            try await group.waitForAll()
        }
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
        let (outputs, _, verifications) = try await process(url: url, settings: settings, tools: tools, allocator: allocator, onPhase: onPhase, onLog: onLog)
        // Single-file entry point: run the deferred verifications before
        // returning so callers (and tests) still observe the "delivered" log
        // lines within the call, matching the batch path's guarantee that
        // verification completes before the run is reported finished.
        for verification in verifications {
            await verification()
        }
        return outputs
    }

    private func process(
        url: URL,
        settings: WaxOffSettings,
        tools: FFmpegManager.Paths,
        allocator: OutputAllocator,
        onPhase: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
    ) async throws -> ([URL], String?, [DeferredVerification]) {
        let ffmpeg = tools.ffmpeg
        var verifications: [DeferredVerification] = []
        // Probe source duration for proportional ffmpeg timeouts (FFmpegRunner.effectiveTimeoutSeconds).
        let fileDuration = await probeFileDuration(ffprobe: tools.ffprobe, url: url)
        let channelCount = await probeChannelCount(ffprobe: tools.ffprobe, url: url)
        let isMono = channelCount == 1
        // True single-channel delivery only when the source is itself mono and the user
        // opted in. For mono delivery there is no dual-mono pair to create the +3 LU
        // measurement quirk, so the upmix workaround is skipped entirely (in both passes)
        // rather than applied and undone. A stereo source ignores the setting outright.
        let deliverMono = isMono && settings.monoDelivery
        let upmixToStereo = isMono && !deliverMono
        let outputChannelCount = deliverMono ? 1 : 2
        if deliverMono { onLog?("  mono delivery: single channel (dual-mono upmix skipped)", .verbose) }

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
        try Task.checkCancellation()
        onLog?("  loudnorm: analyzing…", .verbose)
        let measurements = try await analyzeAudio(ffmpeg: ffmpeg, input: url, settings: settings, upmixToStereo: upmixToStereo, fileDuration: fileDuration)
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
        try Task.checkCancellation()
        onLog?("  loudnorm: normalizing…", .verbose)
        onLog?("  limiter: 2× oversample (\(settings.sampleRate * 2) Hz)  |  ceiling \(tp) dBTP  |  attack 5 ms  |  release 50 ms", .verbose)
        let wavTempURL = FileManager.waxonTempDirectory.appendingPathComponent("\(outputStem).\(UUID().uuidString.prefix(8)).wav")
        let wavFinalURL = outputDir.appendingPathComponent("\(outputStem).wav")

        try await renderWAV(
            ffmpeg: ffmpeg,
            input: url,
            output: wavTempURL,
            settings: settings,
            upmixToStereo: upmixToStereo,
            outputChannelCount: outputChannelCount,
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
            try FileManager.moveAtomically(at: wavTempURL, to: wavFinalURL)
            // wavTempURL is now gone (moved or deleted after cross-volume copy); defer is a no-op
            outputURLs.append(wavFinalURL)
            onLog?("✓ \(wavFinalURL.lastPathComponent)", .info)
            onLog?("  → \(wavFinalURL.path)", .verbose)
            verifications.append { [ffmpeg] in
                await self.verifyDeliveredWAV(ffmpeg: ffmpeg, output: wavFinalURL, fileDuration: fileDuration, onLog: onLog)
            }
        }

        // Phase 3: Encode MP3 (if needed)
        if settings.outputMode == .mp3 || settings.outputMode == .both {
            onPhase?("Encoding MP3…")
            try Task.checkCancellation()
            let mp3TPCeiling = settings.truePeak - 1.0
            onLog?("  mp3: \(settings.mp3Bitrate)k  |  limiter: 2× oversample  |  ceiling \(String(format: "%.1f", mp3TPCeiling)) dBTP", .verbose)

            let sourceForMP3 = settings.outputMode == .both ? wavFinalURL : wavTempURL
            let mp3TempURL = FileManager.waxonTempDirectory.appendingPathComponent("\(outputStem).\(UUID().uuidString.prefix(8)).mp3")
            let mp3FinalURL = outputDir.appendingPathComponent("\(outputStem).mp3")

            defer {
                // wavTempURL is covered by the outer defer above.
                try? FileManager.default.removeItem(at: mp3TempURL)
            }

            do {
                try await encodeMP3(
                    ffmpeg: ffmpeg,
                    input: sourceForMP3,
                    output: mp3TempURL,
                    settings: settings,
                    outputChannelCount: outputChannelCount,
                    fileDuration: fileDuration
                )

                guard FileManager.default.fileExists(atPath: mp3TempURL.path) else {
                    throw DeliveryError.encodingFailed("MP3 file was not created")
                }

                try? FileManager.default.removeItem(at: mp3FinalURL)
                try FileManager.moveAtomically(at: mp3TempURL, to: mp3FinalURL)
                outputURLs.append(mp3FinalURL)
                onLog?("✓ \(mp3FinalURL.lastPathComponent)", .info)
                onLog?("  → \(mp3FinalURL.path)", .verbose)
                // MP3 verification intentionally stays on loudnorm's measurement
                // pass (unlike the WAV path above): its internal 192 kHz resample
                // resolves inter-sample peaks of lossy-decoded audio that
                // ebur128's fixed 4× interpolator underreads — measured 0.156 dB
                // low on a real music episode's MP3 versus an 8×/16× oversampled
                // reference that matched loudnorm within 0.003 dB. See commit
                // ef58d71 and docs/dev/perf-2026-07/meter-agreement.md for the
                // full evidence table. Do not "unify" the two verification paths.
                verifications.append { [ffmpeg] in
                    await self.verifyDelivered(ffmpeg: ffmpeg, output: mp3FinalURL, settings: settings, fileDuration: fileDuration, onLog: onLog)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if settings.outputMode == .both {
                    // WAV is already at wavFinalURL — partial success. The WAV's
                    // deferred verification still runs; no MP3 verification was
                    // queued since the encode never produced a file.
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    onLog?("⚠ MP3 encoding failed: \(msg)", .info)
                    return (outputURLs, msg, verifications)
                }
                throw error  // mp3-only mode: total failure
            }
        }

        return (outputURLs, nil, verifications)
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

    /// Probe the channel count of stream a:0. Returns nil on ffprobe error or an
    /// implausible value; callers treat nil as "channel count unknown" (stereo assumed).
    private func probeChannelCount(ffprobe: String, url: URL) async -> Int? {
        guard let output = try? await FFmpegRunner.captureStdout(exe: ffprobe, args: [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=channels",
            "-of", "default=nw=1:nk=1",
            url.path
        ]) else { return nil }
        let str = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(str), n >= 1, n <= 32 else { return nil }
        return n
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
        upmixToStereo: Bool,
        fileDuration: TimeInterval?
    ) async throws -> LoudnormMeasurements? {
        let lufs = formatNumber(settings.targetLUFS)
        let tp   = String(format: "%.1f", settings.truePeak)
        let lra  = formatNumber(settings.lra)
        // A mono source delivered as stereo is upmixed to dual-mono first so loudnorm
        // measures the stereo signal — matching what renderWAV will produce. (Skipped
        // for true mono delivery, where both passes operate on the native single channel.)
        // Phase rotation runs next so loudnorm's TP measurement reflects the post-rotation
        // waveform; without that the pass-2 gain correction overshoots target.
        let upmix = upmixToStereo ? "pan=stereo|c0=c0|c1=c0," : ""
        let filterChain = "\(upmix)allpass=f=200:t=q:w=0.707,loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra):print_format=json"

        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", input.path, "-map", "0:a:0",
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

    /// Post-render verification for the WAV output: re-measure the delivered
    /// file with `ebur128=peak=true` and log its integrated loudness and true
    /// peak. Purely advisory — never throws; a measurement hiccup only
    /// downgrades to a verbose note. Values are read at full precision from
    /// the filter's frame metadata (the stderr Summary block only prints one
    /// decimal). ebur128 is used here because loudnorm's measurement mode
    /// costs ~5× as much (internal 192 kHz resample) for an advisory readout;
    /// on linear PCM the two meters agree within 0.01 dB. The MP3 path keeps
    /// loudnorm — see the comment at its call site.
    private func verifyDeliveredWAV(
        ffmpeg: String,
        output: URL,
        fileDuration: TimeInterval?,
        onLog: (@Sendable (String, LogLevel) -> Void)?
    ) async {
        guard let m = await measureWAVOutput(ffmpeg: ffmpeg, output: output, fileDuration: fileDuration) else {
            onLog?("  could not verify \(output.lastPathComponent) — output loudness/true-peak not measured", .verbose)
            return
        }
        onLog?(String(format: "  delivered %@: %.1f LUFS · %.1f dBTP", output.lastPathComponent, m.integrated, m.truePeakDB), .info)
        onLog?(String(format: "  measured %@: I=%.2f LUFS  TP=%.2f dBTP  LRA=%.2f LU",
                      output.lastPathComponent, m.integrated, m.truePeakDB, m.lra), .verbose)
    }

    /// EBU R128 measurement of a delivered WAV via ebur128 with true-peak mode
    /// (4× oversampled per BS.1770), full-precision values from frame metadata
    /// printed to stdout. Returns nil if the pass or parse fails.
    private func measureWAVOutput(
        ffmpeg: String,
        output: URL,
        fileDuration: TimeInterval?
    ) async -> FFmpegRunner.Ebur128Reading? {
        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", output.path, "-map", "0:a:0",
            "-af", "ebur128=peak=true:metadata=1,ametadata=mode=print:file=-",
            "-f", "null", "-"
        ]
        guard let stdout = try? await FFmpegRunner.captureStdout(exe: ffmpeg, args: args, fileDuration: fileDuration),
              let m = FFmpegRunner.parseEbur128FrameMetadata(from: stdout)
        else { return nil }
        return m
    }

    /// Post-render verification for the MP3 output: re-measure with a loudnorm
    /// measurement pass and log integrated loudness and true peak. Purely
    /// advisory — the render already succeeded and the file is delivered, so
    /// this never throws and a measurement hiccup only downgrades to a verbose
    /// note. (Kept on loudnorm deliberately; see the call-site comment.)
    private func verifyDelivered(
        ffmpeg: String,
        output: URL,
        settings: WaxOffSettings,
        fileDuration: TimeInterval?,
        onLog: (@Sendable (String, LogLevel) -> Void)?
    ) async {
        guard let m = await measureOutput(ffmpeg: ffmpeg, output: output, settings: settings, fileDuration: fileDuration) else {
            onLog?("  could not verify \(output.lastPathComponent) — output loudness/true-peak not measured", .verbose)
            return
        }
        onLog?(String(format: "  delivered %@: %.1f LUFS · %.1f dBTP", output.lastPathComponent, m.inputI, m.inputTP), .info)
        onLog?(String(format: "  measured %@: I=%.2f LUFS  TP=%.2f dBTP  LRA=%.2f LU  thresh=%.2f LUFS",
                      output.lastPathComponent, m.inputI, m.inputTP, m.inputLRA, m.inputThresh), .verbose)
    }

    /// Loudnorm analysis pass over a finished output file, reusing the same
    /// capture + JSON parsing path as the pre-render analysis. The target
    /// params don't affect the reported `input_*` values, so any valid
    /// loudnorm call returns the output's own integrated loudness / true peak.
    /// Returns nil if the pass or parse fails.
    private func measureOutput(
        ffmpeg: String,
        output: URL,
        settings: WaxOffSettings,
        fileDuration: TimeInterval?
    ) async -> LoudnormMeasurements? {
        let lufs = formatNumber(settings.targetLUFS)
        let tp   = String(format: "%.1f", settings.truePeak)
        let lra  = formatNumber(settings.lra)
        let args = [
            "-hide_banner", "-nostats", "-y",
            "-i", output.path, "-map", "0:a:0",
            "-af", "loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra):print_format=json",
            "-f", "null", "-"
        ]
        guard let stderr = try? await FFmpegRunner.capture(exe: ffmpeg, args: args, fileDuration: fileDuration),
              let dict = FFmpegRunner.parseLoudnormJSON(from: stderr),
              let m = LoudnormMeasurements(json: dict.mapValues { $0 as Any })
        else { return nil }
        return m
    }

    private func renderWAV(
        ffmpeg: String,
        input: URL,
        output: URL,
        settings: WaxOffSettings,
        upmixToStereo: Bool,
        outputChannelCount: Int,
        measurements: LoudnormMeasurements?,
        fileDuration: TimeInterval?
    ) async throws {
        // A mono source delivered as stereo is upmixed to dual-mono first — matching the
        // analyzeAudio filter chain so measured_I / offset remain valid for the stereo
        // signal. (Skipped for true mono delivery; both passes then use the native channel.)
        // Phase rotation always runs. Loudnorm only runs when measurements
        // are available — silent inputs skip it to avoid pass-2 errors.
        let upmix = upmixToStereo ? "pan=stereo|c0=c0|c1=c0," : ""
        var filterChain = "\(upmix)allpass=f=200:t=q:w=0.707"
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
            "-i", input.path, "-map", "0:a:0",
            "-af", filterChain,
            // Carry container-level metadata (title/artist/album/comment, BWF
            // chunks on WAV→WAV) from the input. FFmpeg's default for filter
            // graphs is to strip global metadata; a podcast delivery workflow
            // usually wants it preserved.
            "-map_metadata", "0",
            "-ar", String(settings.sampleRate),
            "-ac", String(outputChannelCount),
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
        outputChannelCount: Int,
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
            "-ac", String(outputChannelCount),
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
    case outputNotCreated
    case processingFailed(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .outputNotCreated:
            return "Output file was not created."
        case .processingFailed(let msg):
            return "Processing failed: \(msg)"
        case .encodingFailed(let msg):
            return "MP3 encoding failed: \(msg)"
        }
    }
}
