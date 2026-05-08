import Foundation

struct JobInput: Sendable {
    let id: UUID
    let url: URL
}

actor AudioProcessor {
    let settings: WaxOnSettings
    let onFileStarted: (@Sendable (UUID) -> Void)?
    let onLog: (@Sendable (String, LogLevel) -> Void)?

    init(settings: WaxOnSettings,
         onFileStarted: (@Sendable (UUID) -> Void)? = nil,
         onLog: (@Sendable (String, LogLevel) -> Void)? = nil) {
        self.settings = settings
        self.onFileStarted = onFileStarted
        self.onLog = onLog
    }

    func run(inputs: [JobInput]) async throws -> [JobResult] {
        guard !inputs.isEmpty else { return [] }

        let tools = try await FFmpegManager.shared.ensureTools()
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        return try await withThrowingTaskGroup(of: JobResult?.self) { group in
            var results: [JobResult] = []
            var index = 0

            func addNext() {
                guard index < inputs.count else { return }
                let input = inputs[index]
                index += 1
                group.addTask {
                    try Task.checkCancellation()
                    self.onFileStarted?(input.id)
                    return try await self.processOne(input.url, id: input.id, tools: tools)
                }
            }

            for _ in 0..<min(maxConcurrent, inputs.count) {
                addNext()
            }

            for try await result in group {
                if let result {
                    results.append(result)
                }
                addNext()
            }

            return results
        }
    }

    private func processOne(_ input: URL, id: UUID, tools: FFmpegManager.Paths) async throws -> JobResult? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else {
            throw ProcessingError.invalidInput
        }

        let sr = settings.sampleRate.rawValue
        let rateTag = sr == 44100 ? "44k" : "48k"
        let stem = input.deletingPathExtension().lastPathComponent
        let filename = input.lastPathComponent
        let limitAmp = pow(10.0, -1.0 / 20.0)
        let outDir = bestOutputDir(for: input)
        let outName = "\(stem)-\(rateTag)waxon.wav"
        let finalURL = outDir.appendingPathComponent(outName)

        let work = try makeTemp(prefix: "waxon_\(rateTag)_")
        defer { try? fm.removeItem(at: work) }

        // Stage inside work so the existing defer cleans it on crash/cancel,
        // and the startup purge handles any orphan from a force-quit.
        let tmpURL = work.appendingPathComponent(outName)

        let isStereo = settings.outputChannels == .stereo
        let channelSuffix = isStereo ? "stereo" : "mono"
        let midURL = work.appendingPathComponent("\(stem)_\(rateTag)24_\(channelSuffix).wav")

        let phaseFilter = settings.phaseRotationEnabled ? "allpass=f=200:t=q:w=0.707," : ""
        let outputChannelCount: String = isStereo ? "2" : "1"

        onLog?("▶ \(filename)", .info)
        let channelDesc = isStereo ? "stereo" : "mono (\(settings.channel.rawValue))"
        let phaseDesc = settings.phaseRotationEnabled ? "  |  phase rotation: 200 Hz" : ""
        let hpFreq = settings.highPassEnabled ? 80 : 20
        onLog?("  filter: highpass=\(hpFreq) Hz\(phaseDesc)  |  \(channelDesc)  |  \(rateTag) kHz", .verbose)

        let step1Af: String
        if isStereo {
            step1Af = "highpass=f=\(hpFreq),\(phaseFilter)aresample=\(sr)"
        } else {
            let pan = settings.channel == .left ? "pan=1c|c0=c0" : "pan=1c|c0=c1"
            step1Af = "highpass=f=\(hpFreq),\(pan),\(phaseFilter)aresample=\(sr)"
        }
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", input.path, "-af", step1Af,
            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, midURL.path
        ])

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
            let dynLevelURL = work.appendingPathComponent("\(stem)_dynleveled.wav")
            let dynFilter = dynamicLevelingFilter(amount: settings.dynamicLevelingAmount)
            onLog?("  dynamic leveling: \(dynFilter)", .verbose)
            let args: [String]
            if let d = try? await getAudioDuration(exe: tools.ffprobe, url: midURL) {
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
            try await FFmpegRunner.run(exe: tools.ffmpeg, args: args)
            postDynLevelURL = dynLevelURL
            try Task.checkCancellation()
        } else {
            postDynLevelURL = midURL
        }

        // Loudness normalization (optional, two-pass EBU R128)
        let limiterInput: URL
        if settings.loudnormEnabled {
            let target = settings.loudnormTarget
            let tp = -1.0

            // Run RNNoise on a temp copy for the analysis pass only.
            // This prevents broadband noise from inflating the loudness measurement,
            // ensuring speech hits the target LUFS more accurately.
            let analysisInput: URL
            if let modelURL = Bundle.main.url(forResource: "rnnoise", withExtension: nil) {
                let nrTempURL = work.appendingPathComponent("\(stem)_nr_analysis.wav")
                onLog?("  loudnorm: applying NR for measurement accuracy…", .verbose)
                let escapedNrModel = ffmpegFilterEscape(modelURL.path)
                if isStereo {
                    let nrFc = [
                        "[0:a]channelsplit=channel_layout=stereo[L][R]",
                        "[L]arnndn=m=\(escapedNrModel)[Lnr]",
                        "[R]arnndn=m=\(escapedNrModel)[Rnr]",
                        "[Lnr][Rnr]join=inputs=2:channel_layout=stereo"
                    ].joined(separator: ";")
                    try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
                        "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", postDynLevelURL.path, "-filter_complex", nrFc,
                        "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, nrTempURL.path
                    ])
                } else {
                    try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
                        "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", postDynLevelURL.path, "-af", "arnndn=m=\(escapedNrModel)",
                        "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, nrTempURL.path
                    ])
                }
                analysisInput = nrTempURL
            } else {
                analysisInput = postDynLevelURL
            }

            let analyzeAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:print_format=json"
            onLog?("  loudnorm: analyzing…", .verbose)
            let analysisOutput = try await FFmpegRunner.capture(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner",
                "-i", analysisInput.path, "-af", analyzeAf,
                "-f", "null", "/dev/null"
            ])

            guard let lnDict = FFmpegRunner.parseLoudnormJSON(from: analysisOutput),
                  let inputI      = lnDict["input_i"],
                  let inputTP     = lnDict["input_tp"],
                  let inputLRA    = lnDict["input_lra"],
                  let inputThresh = lnDict["input_thresh"],
                  let targetOffset = lnDict["target_offset"] else {
                throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse loudnorm analysis output")
            }
            onLog?("  measured: \(inputI) LUFS  |  TP \(inputTP) dBTP  |  LRA \(inputLRA) LU", .info)
            onLog?("  target: \(target) LUFS  |  offset \(targetOffset) dB  |  thresh \(inputThresh) LUFS", .verbose)
            onLog?("  loudnorm: normalizing…", .verbose)

            let normURL = work.appendingPathComponent("\(stem)_norm.wav")
            let normAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:measured_I=\(inputI):measured_TP=\(inputTP):measured_LRA=\(inputLRA):measured_thresh=\(inputThresh):offset=\(targetOffset):linear=true"

            try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", postDynLevelURL.path, "-af", normAf,
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, normURL.path
            ])

            limiterInput = normURL
        } else {
            limiterInput = postDynLevelURL
        }

        try Task.checkCancellation()

        let oversampleSr = sr * 2

        let step2Af = [
            "aresample=\(oversampleSr)",
            "alimiter=limit=\(limitAmp):attack=5:release=50:level=disabled",
            "aresample=\(sr)"
        ].joined(separator: ",")

        onLog?("  limiter: 2× oversample (\(oversampleSr) Hz)  |  ceiling −1.0 dBTP  |  attack 5 ms  |  release 50 ms", .verbose)

        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", limiterInput.path, "-af", step2Af,
            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, "-f", "wav", tmpURL.path
        ])

        guard let attrs = try? fm.attributesOfItem(atPath: tmpURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0 else {
            throw ProcessingError.outputMissing
        }

        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: tmpURL, to: finalURL)

        onLog?("✓ \(outName)", .info)
        onLog?("  → \(finalURL.path)", .verbose)
        return JobResult(id: id, input: input, output: finalURL)
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

    /// Escape a string for safe use inside an FFmpeg filtergraph value.
    /// Handles the five characters the filtergraph parser treats as syntax.
    private nonisolated func ffmpegFilterEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'",  with: "\\'")
         .replacingOccurrences(of: ":",  with: "\\:")
         .replacingOccurrences(of: "[",  with: "\\[")
         .replacingOccurrences(of: "]",  with: "\\]")
    }

    // Maps 0.0 (gentle) → 1.0 (aggressive) to dynaudnorm parameters.
    // Shorter frames and tighter Gaussian smoothing = more responsive leveling.
    // No t (silence threshold): an active threshold causes severe attenuation at
    // speech-to-silence transitions because the Gaussian window interpolates
    // between gated (unity-gain) and ungated frames, producing audible fade-outs
    // on the trailing edge of every utterance. The cost of dropping t is that the
    // noise floor between words gets boosted by up to m dB — acceptable on the
    // clean source material Dynamic Leveling targets (panel / multi-voice).
    private func dynamicLevelingFilter(amount: Double) -> String {
        let f = Int(500.0 - amount * 350.0)         // frame ms: 500 → 150
        let gRaw = Int(31.0 - amount * 16.0)        // gaussian: 31 → 15
        let g = gRaw % 2 == 0 ? gRaw - 1 : gRaw    // must be odd
        let m = 2.0 + amount * 4.0                  // max gain factor: 2x → 6x (+6 to +15 dB)
        return "dynaudnorm=f=\(f):g=\(g):p=0.95:m=\(String(format: "%.1f", m))"
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
        return d
    }

    private func bestOutputDir(for input: URL) -> URL {
        let fm = FileManager.default

        if let customPath = settings.outputDirectoryPath {
            let customURL = URL(fileURLWithPath: customPath, isDirectory: true)
            if fm.isWritableFile(atPath: customURL.path) { return customURL }
            onLog?("⚠ Custom output directory not writable (\(customPath)), falling back.", .info)
        }

        let here = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: here.path) { return here }

        onLog?("⚠ Source directory not writable, falling back to ~/Music/WaxOnWaxOff.", .info)
        let music = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music/WaxOnWaxOff", isDirectory: true)
        if (try? fm.createDirectory(at: music, withIntermediateDirectories: true)) != nil {
            return music
        }

        onLog?("⚠ ~/Music/WaxOnWaxOff unavailable, falling back to Desktop.", .info)
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
