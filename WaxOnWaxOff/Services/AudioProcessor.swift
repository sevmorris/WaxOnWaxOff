import Foundation
import OSLog

nonisolated private let audioProcessorLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "AudioProcessor")

struct JobInput: Sendable {
    let id: UUID
    let url: URL
}

actor AudioProcessor {
    let settings: WaxOnSettings
    let onFileStarted: (@Sendable (UUID) -> Void)?
    let onFileCompleted: (@Sendable (JobResult) -> Void)?
    let onFileFailed: (@Sendable (WaxOnJobFailure) -> Void)?
    let onLog: (@Sendable (String, LogLevel) -> Void)?

    init(settings: WaxOnSettings,
         onFileStarted: (@Sendable (UUID) -> Void)? = nil,
         onFileCompleted: (@Sendable (JobResult) -> Void)? = nil,
         onFileFailed: (@Sendable (WaxOnJobFailure) -> Void)? = nil,
         onLog: (@Sendable (String, LogLevel) -> Void)? = nil) {
        self.settings = settings
        self.onFileStarted = onFileStarted
        self.onFileCompleted = onFileCompleted
        self.onFileFailed = onFileFailed
        self.onLog = onLog
    }

    func run(inputs: [JobInput]) async throws -> WaxOnBatchRunResult {
        guard !inputs.isEmpty else {
            return WaxOnBatchRunResult(successes: [], failures: [])
        }

        let tools = try await FFmpegManager.shared.ensureTools()
        let sr = settings.sampleRate.rawValue
        let rateTag = sr == 44100 ? "44k" : "48k"
        let allocator = OutputAllocator { [rateTag] input in
            "\(input.deletingPathExtension().lastPathComponent)-\(rateTag)waxon.wav"
        }

        let outcomes: [Result<JobResult, WaxOnJobFailure>] = try await runBoundedConcurrent(
            inputs: inputs,
            limit: ProcessingConfig.maxConcurrentJobs
        ) { input in
            do {
                try Task.checkCancellation()
                self.onFileStarted?(input.id)
                guard let result = try await self.processOne(input.url, id: input.id, tools: tools, allocator: allocator) else {
                    let failure = WaxOnJobFailure(
                        id: input.id,
                        message: ProcessingError.outputMissing.errorDescription ?? "No output produced"
                    )
                    self.onFileFailed?(failure)
                    return .failure(failure)
                }
                self.onFileCompleted?(result)
                return .success(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.onLog?("✗ \(input.url.lastPathComponent): \(message)", .info)
                let failure = WaxOnJobFailure(id: input.id, message: message)
                self.onFileFailed?(failure)
                return .failure(failure)
            }
        }

        var successes: [JobResult] = []
        var failures: [WaxOnJobFailure] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let r): successes.append(r)
            case .failure(let f): failures.append(f)
            }
        }
        return WaxOnBatchRunResult(successes: successes, failures: failures)
    }

    /// Renders exactly one output file. Called once for Mono and Stereo, and
    /// twice for Split L/R — once per source channel, each with its own
    /// measurement and gain.
    private func renderOne(
        _ input: URL,
        tools: FFmpegManager.Paths,
        allocator: OutputAllocator,
        channel: WaxOnSettings.MonoChannel,
        forceMono: Bool,
        variant: String?,
        inputChannelCount: Int,
        fileDuration: TimeInterval?
    ) async throws -> URL {
        let fm = FileManager.default
        let sr = settings.sampleRate.rawValue
        let rateTag = sr == 44100 ? "44k" : "48k"
        let stem = input.deletingPathExtension().lastPathComponent
        let filename = input.lastPathComponent
        // WaxOn's ceiling is fixed at -1.0 (not user-adjustable); matches the
        // theory.html "Under the Hood" value of ~0.891251. Units differ by path:
        // this amplitude is the alimiter's dBFS sample-peak ceiling on the
        // loudnorm-on path, while the off path below reuses the same -1.0 figure
        // as a dBTP true-peak target reached by attenuation alone.
        let limitAmp = FFmpegFilters.limiterCeilingAmplitude(dBFS: -1.0)
        let outDir = OutputDirectory.waxOnOutputDirectory(for: input, settings: settings) { [self] message in
            self.onLog?("⚠ \(message)", .info)
        }
        let finalURL = allocator.allocate(for: input, in: outDir, variant: variant)
        let outName = finalURL.lastPathComponent

        let work = try makeTemp(prefix: "waxon_\(rateTag)_")
        defer { try? fm.removeItem(at: work) }

        // Stage inside work so the existing defer cleans it on crash/cancel.
        // The startup purge covers only the current PID's subtree — a force-quit
        // leaves an orphaned subtree in /tmp until the OS reclaims it (~3 days).
        let tmpURL = work.appendingPathComponent(outName)

        // All intermediate files use pcm_s24le throughout. At 24-bit, the quantization
        // noise floor sits at ~−144 dBFS — inaudible in any real-world context. Adding
        // TPDF dither between pipeline stages would add filter-graph complexity for zero
        // perceptible benefit. Dither is also not applied at the final export stage; see
        // FFmpegFilters.aresample and theory.html §Dithering for the full rationale.
        let isStereo = !forceMono
        let channelSuffix = isStereo ? "stereo" : "mono"
        let midURL = work.appendingPathComponent("\(stem)_\(rateTag)24_\(channelSuffix).wav")

        let phaseFilter = settings.phaseRotationEnabled ? "allpass=f=200:t=q:w=0.707," : ""
        let outputChannelCount: String = isStereo ? "2" : "1"

        onLog?(variant.map { "▶ \(filename)  [\($0)]" } ?? "▶ \(filename)", .info)
        let channelDesc = isStereo ? "stereo" : "mono (\(channel.rawValue))"
        let phaseDesc = settings.phaseRotationEnabled ? "  |  phase rotation: 200 Hz" : ""
        let hpFreq = settings.highPassEnabled ? 80 : 20
        onLog?("  filter: highpass=\(hpFreq) Hz\(phaseDesc)  |  \(channelDesc)  |  \(rateTag) kHz", .verbose)

        let step1Af: String
        if isStereo {
            // `-ac 2` below folds a >2-channel source down via FFmpeg's default
            // matrix. Warn for parity with the mono path, which already warns on
            // the equivalent conversion — a channel-destructive change should not
            // be silent in one output mode and announced in the other.
            if inputChannelCount > 2 {
                onLog?("⚠ \(inputChannelCount)-channel input — downmixing to stereo via FFmpeg's default matrix.", .info)
            }
            step1Af = "highpass=f=\(hpFreq),\(phaseFilter)\(FFmpegFilters.aresample(to: sr))"
        } else {
            // For >2 channel sources (5.1, 7.1, ambisonic), the user's Left/Right
            // selection picks input channel 0 or 1 — which on a 5.1 stem skips
            // the center channel where dialogue typically lives. Fall back to
            // FFmpeg's default mono downmix matrix for those cases so center
            // and surrounds are summed in.
            let pan: String
            if inputChannelCount == 1 {
                // A 1-channel source has no c1; pan=1c|c0=c1 would error at
                // graph configuration. Pass the single channel through and
                // note that the L/R pick is irrelevant for mono input.
                pan = "aformat=channel_layouts=mono"
                onLog?("⚠ Input is mono; channel selection ignored.", .info)
            } else if inputChannelCount > 2 {
                pan = "aformat=channel_layouts=mono"
                onLog?("⚠ \(inputChannelCount)-channel input — using mono downmix instead of \(channel.rawValue) channel pick.", .info)
            } else {
                pan = channel == .left ? "pan=1c|c0=c0" : "pan=1c|c0=c1"
            }
            step1Af = "highpass=f=\(hpFreq),\(pan),\(phaseFilter)\(FFmpegFilters.aresample(to: sr))"
        }
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", input.path, "-map", "0:a:0", "-af", step1Af,
            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, midURL.path
        ], fileDuration: fileDuration)

        try Task.checkCancellation()

        // Dynamic leveling (optional, dynaudnorm bidirectional)
        // Mirror padding: dynaudnorm's Gaussian smoothing window extends into nonexistent
        // frames at the file boundaries. Padding with silence doesn't help — silent frames
        // get gain=1.0 (silence threshold) which still pulls the smoothed gain down at the
        // audio boundary, producing a ramp. Mirror padding (reversed copies of the first
        // and last 16s) gives the smoothing window real audio with matching gain values
        // on both sides of the boundary.
        let postDynLevelURL: URL
        if settings.dynamicLevelingEnabled {
            let duration = fileDuration  // probed at start of processOne; resampling preserves duration
            let amount = settings.dynamicLevelingAmount
            // Half of the dynaudnorm Gaussian window (g hops × frame_ms). Mirror
            // padding only works if the clip is at least this long — otherwise
            // the smoothing window peeks past the padded edge.
            let frameMs = 500.0 - amount * 350.0
            // Use the canonical gaussian window size (same formula as the dynaudnorm
            // g= parameter) so the smoothing-radius estimate matches the actual filter.
            let gauss = gaussianWindowSize(amount: amount)
            let smoothingRadiusS = Double(gauss) * frameMs / 1000.0 / 2.0

            if let d = duration, d < 2.0 {
                onLog?("⚠ Clip is shorter than 2 s — dynamic leveling skipped.", .info)
                postDynLevelURL = midURL
            } else {
                let dynLevelURL = work.appendingPathComponent("\(stem)_dynleveled.wav")
                let dynFilter = dynamicLevelingFilter(amount: amount)
                onLog?("  dynamic leveling: \(dynFilter)", .verbose)
                if let d = duration, d < smoothingRadiusS {
                    onLog?(String(format: "⚠ Clip (%.1fs) is shorter than dynaudnorm's smoothing radius (%.1fs); boundary smoothing will be approximate.", d, smoothingRadiusS), .info)
                }
                let args: [String]
                if let d = duration {
                    let filterComplex = mirrorPaddedFilter(duration: d, leveler: dynFilter)
                    args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                            "-i", midURL.path,
                            "-filter_complex", filterComplex,
                            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, dynLevelURL.path]
                } else {
                    onLog?("⚠ Could not determine file duration; dynaudnorm boundary fix skipped.", .info)
                    args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                            "-i", midURL.path,
                            "-af", dynFilter,
                            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, dynLevelURL.path]
                }
                try await FFmpegRunner.run(exe: tools.ffmpeg, args: args, fileDuration: fileDuration)
                postDynLevelURL = dynLevelURL
            }
            try Task.checkCancellation()
        } else {
            postDynLevelURL = midURL
        }

        // One EBU R128 pass over the post-filter / post-leveling intermediate serves
        // both routes: Loudness Norm takes its integrated loudness and applies a single
        // constant gain; with Norm off, its true peak drives downward-only peak
        // normalization. WaxOn is an ingest stage feeding a DAW, so a constant gain to a
        // staging target is all it needs. FFmpeg's two-pass loudnorm did the same job —
        // it ran with linear=true, which is by definition one constant gain — at roughly
        // four times the cost, and measured no more accurately: across a five-source
        // corpus the largest miss was 0.23 LU for loudnorm versus 0.00 LU for this path.
        let limiterInput = postDynLevelURL
        let ceiling = -1.0
        onLog?("  measuring loudness and true peak…", .verbose)
        let reading = try await measureLoudness(exe: tools.ffmpeg, url: limiterInput, fileDuration: fileDuration)

        try Task.checkCancellation()

        let gainDB: Double
        let renderAf: String

        if settings.loudnormEnabled {
            let target = settings.loudnormTarget
            // ebur128 floors at exactly −70 LUFS (the BS.1770 absolute gate) for silent
            // and near-silent input, where loudnorm used to report -inf. Treat the floor
            // as "nothing to measure" so silence is passed through rather than boosted.
            if let r = reading, r.integrated > -70.0 {
                gainDB = target - r.integrated
                onLog?(String(format: "  measured: %.1f LUFS  |  TP %.1f dBTP", r.integrated, r.truePeakDB), .info)
                if abs(gainDB) > 12.0 {
                    onLog?(String(format: "⚠ Large gain change (%+.1f dB) — verify the source level and output before delivery.",
                                  gainDB), .info)
                }
                onLog?(String(format: "  Δ %+.1f dB applied  |  %.1f LUFS → %.0f LUFS",
                              gainDB, r.integrated, target), .info)
            } else {
                gainDB = 0.0
                onLog?("⚠ Input is silent or near-silent — loudness normalization skipped.", .info)
            }
            onLog?("  limiter: ceiling −1.0 dBFS  |  attack 5 ms  |  release 50 ms", .verbose)
            renderAf = "volume=\(String(format: "%.6f", gainDB))dB,"
                + "alimiter=limit=\(limitAmp):attack=5:release=50:level=disabled"
        } else {
            // Downward-only true-peak normalization: at most a single attenuation to the
            // ceiling, so a source already inside it passes through untouched (gain 0).
            if let tp = reading?.truePeakDB, tp.isFinite {
                gainDB = min(0.0, ceiling - tp)
                if gainDB < 0 {
                    onLog?(String(format: "  true peak %.1f dBTP → %.1f dB linear gain to %.1f dBTP (no limiting)", tp, gainDB, ceiling), .info)
                } else {
                    onLog?(String(format: "  true peak %.1f dBTP within %.1f ceiling — passed through unmodified", tp, ceiling), .info)
                }
            } else {
                gainDB = 0.0
                onLog?("⚠ Input is silent or its true peak could not be measured — passed through unmodified.", .info)
            }
            renderAf = "volume=\(String(format: "%.6f", gainDB))dB"
        }

        try? fm.removeItem(at: tmpURL)

        // Single render. At 0 dB gain with Norm off this is a transparent copy.
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", limiterInput.path, "-af", renderAf,
            "-map_metadata", "0",
            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, "-f", "wav", tmpURL.path
        ], fileDuration: fileDuration)

        guard let attrs = try? fm.attributesOfItem(atPath: tmpURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0 else {
            throw ProcessingError.outputMissing
        }

        try? fm.removeItem(at: finalURL)
        try FileManager.moveAtomically(at: tmpURL, to: finalURL)

        onLog?("✓ \(outName)", .info)
        onLog?("  → \(finalURL.path)", .verbose)
        return finalURL
    }

    /// Probes the source once, then renders the one or two files this job owes.
    private func processOne(_ input: URL, id: UUID, tools: FFmpegManager.Paths, allocator: OutputAllocator) async throws -> JobResult? {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ProcessingError.invalidInput
        }

        // Probed once and shared by every render below: a split job runs the
        // pipeline twice over the same source, and re-probing would be pure cost.
        let inputChannelCount = try await getChannelCount(exe: tools.ffprobe, url: input)
        // Used for proportional ffmpeg timeouts (FFmpegRunner.effectiveTimeoutSeconds)
        // and for dynaudnorm boundary math when leveling is enabled.
        let fileDuration: TimeInterval? = try? await getAudioDuration(exe: tools.ffprobe, url: input)

        guard settings.outputChannels == .splitLR else {
            let only = try await renderOne(
                input, tools: tools, allocator: allocator,
                channel: settings.channel,
                forceMono: settings.outputChannels == .mono,
                variant: nil,
                inputChannelCount: inputChannelCount, fileDuration: fileDuration
            )
            return JobResult(id: id, input: input, outputs: [only])
        }

        guard inputChannelCount == 2 else {
            onLog?("⚠ Split L/R needs a two-channel source — \(input.lastPathComponent) has \(inputChannelCount). Writing one mono file instead.", .info)
            let only = try await renderOne(
                input, tools: tools, allocator: allocator,
                channel: settings.channel, forceMono: true, variant: nil,
                inputChannelCount: inputChannelCount, fileDuration: fileDuration
            )
            return JobResult(id: id, input: input, outputs: [only])
        }

        // Each channel is measured and gained on its own. For a two-microphone
        // recording the channels are separate mono takes sharing a container —
        // there is no stereo image to preserve, and coupling them would defeat
        // the point, which is that each speaker reaches the DAW at a consistent
        // level regardless of how they sat relative to their microphone.
        let left = try await renderOne(
            input, tools: tools, allocator: allocator,
            channel: .left, forceMono: true, variant: "L",
            inputChannelCount: inputChannelCount, fileDuration: fileDuration
        )
        try Task.checkCancellation()
        let right = try await renderOne(
            input, tools: tools, allocator: allocator,
            channel: .right, forceMono: true, variant: "R",
            inputChannelCount: inputChannelCount, fileDuration: fileDuration
        )
        return JobResult(id: id, input: input, outputs: [left, right])
    }

    /// Single EBU R128 pass over `url` with true-peak metering, read from the
    /// filter's frame metadata at full precision (the stderr summary only carries
    /// one decimal). One call serves both the integrated-loudness and true-peak
    /// needs of the render. Returns nil if the pass or parse fails; callers treat
    /// nil as "apply no gain". Cancellation is propagated.
    private func measureLoudness(exe: String, url: URL, fileDuration: TimeInterval?) async throws -> FFmpegRunner.Ebur128Reading? {
        let analyzeAf = "ebur128=peak=true:metadata=1,ametadata=mode=print:file=-"
        let output: String
        do {
            output = try await FFmpegRunner.captureStdout(exe: exe, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", url.path, "-af", analyzeAf,
                "-f", "null", "/dev/null"
            ], fileDuration: fileDuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        return FFmpegRunner.parseEbur128FrameMetadata(from: output)
    }

    private func makeTemp(prefix: String) throws -> URL {
        let dir = FileManager.waxonTempDirectory
            .appendingPathComponent(prefix + UUID().uuidString.prefix(8), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ProcessingError.tempDirectoryFailed
        }
        return dir
    }

    /// Dynaudnorm Gaussian window size for the given leveling `amount` (0–1).
    /// Returns an odd integer in [15, 31]: the value passed to dynaudnorm's `g=`
    /// parameter. Floored then forced odd — matches the filter's own requirement
    /// and ensures the smoothing-radius estimate in `processOne` uses the same value.
    private func gaussianWindowSize(amount: Double) -> Int {
        let gRaw = Int(31.0 - amount * 16.0)        // gaussian: 31 → 15
        return gRaw % 2 == 0 ? gRaw - 1 : gRaw     // must be odd
    }

    // Shorter frames and tighter Gaussian smoothing = more responsive leveling.
    // No t (silence threshold): an active threshold causes severe attenuation at
    // speech-to-silence transitions because the Gaussian window interpolates
    // between gated (unity-gain) and ungated frames, producing audible fade-outs
    // on the trailing edge of every utterance. The cost of dropping t is that the
    // noise floor between words gets boosted by up to m dB — acceptable on the
    // clean source material Dynamic Leveling targets (panel / multi-voice).
    private func dynamicLevelingFilter(amount: Double) -> String {
        let f = Int(500.0 - amount * 350.0)          // frame ms: 500 → 150
        let g = gaussianWindowSize(amount: amount)   // gaussian: 31 → 15 (odd)
        let m = 2.0 + amount * 4.0                  // max gain factor: 2x → 6x (+6 to +15 dB)
        // c=0 (channel-coupling off) keeps stereo gain decisions decoupled —
        // the default in modern FFmpeg, but pinned explicitly so behavior
        // stays stable across FFmpeg upgrades.
        return "dynaudnorm=f=\(f):g=\(g):p=0.95:m=\(String(format: "%.1f", m)):c=0"
    }

    // Builds a filter_complex that mirror-pads the audio with reversed copies of the
    // first and last `padDur` seconds (capped at 16s, or the file length if shorter),
    // runs the leveler over the padded stream, then trims the padding back off.
    private func mirrorPaddedFilter(duration: Double, leveler: String) -> String {
        let padDur = min(16.0, duration)
        let tailStart = max(0.0, duration - padDur)
        let pad = String(format: "%.6f", padDur)
        let tStart = String(format: "%.6f", tailStart)
        let dur = String(format: "%.6f", duration)
        return "[0:a]asplit=3[h][m][t];" +
               "[h]atrim=duration=\(pad),areverse,asetpts=PTS-STARTPTS[head];" +
               "[m]asetpts=PTS-STARTPTS[body];" +
               "[t]atrim=start=\(tStart),areverse,asetpts=PTS-STARTPTS[tail];" +
               "[head][body][tail]concat=n=3:v=0:a=1," +
               "\(leveler),atrim=start=\(pad):duration=\(dur),asetpts=PTS-STARTPTS"
    }

    private nonisolated func getAudioDuration(exe: String, url: URL) async throws -> Double {
        let output = try await FFmpegRunner.captureStdout(exe: exe, args: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ])
        let str = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(str) else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse audio duration")
        }
        // Guard against non-finite, negative, or absurd values from corrupt container
        // headers — Int((d * 4.0).rounded()) traps on overflow for large doubles.
        // 30 days is a generous ceiling that covers any real podcast or long-form file.
        let maxDuration: Double = 30 * 24 * 3600
        guard d.isFinite, d >= 0, d <= maxDuration else {
            audioProcessorLogger.warning("Implausible audio duration '\(str, privacy: .public)' from \(url.lastPathComponent, privacy: .public) — ignoring, will use default timeout")
            throw ProcessingError.ffmpegFailed(code: -1, message: "Implausible audio duration (\(str))")
        }
        return d
    }

    private nonisolated func getChannelCount(exe: String, url: URL) async throws -> Int {
        let output = try await FFmpegRunner.captureStdout(exe: exe, args: [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=channels",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ])
        let str = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(str), n > 0 else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse channel count")
        }
        guard n <= 64 else {
            throw ProcessingError.ffmpegFailed(
                code: -1,
                message: "Unexpected channel count (\(n)) — expected 1–64 channels"
            )
        }
        return n
    }
}
