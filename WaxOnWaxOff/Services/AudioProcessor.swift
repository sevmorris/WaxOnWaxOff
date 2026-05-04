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
        let limitAmp = pow(10.0, settings.limitDb / 20.0)
        let limitTag = formatDbTag(settings.limitDb)
        let outDir = bestOutputDir(for: input)
        let outName = "\(stem)-\(rateTag)waxon\(limitTag).wav"
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
        let hpFreq = max(settings.highPassHz, 20)
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

        // dynaudnorm boundary fix: the Gaussian window looks back into prior loud frames
        // when computing gain for the tail, causing the voice to fade. Padding the input
        // with silence pushes the artifact into the padding; -t trims it from the output.
        var dynaudnormDuration: Double? = nil
        if settings.levelRidingEnabled || settings.dynamicLevelingEnabled {
            if let d = try? await getAudioDuration(exe: tools.ffprobe, url: midURL) {
                dynaudnormDuration = d
            } else {
                onLog?("⚠ Could not determine file duration; dynaudnorm tail-fade fix skipped.", .info)
            }
        }

        // Level riding (optional, dynaudnorm downward-only)
        let postLevelURL: URL
        if settings.levelRidingEnabled {
            let levelURL = work.appendingPathComponent("\(stem)_leveled.wav")
            onLog?("  level riding: dynaudnorm (downward only, no boost)", .verbose)
            var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", midURL.path,
                        "-af", "apad=pad_dur=16,dynaudnorm=p=0.95:m=1.0:g=31"]
            if let d = dynaudnormDuration { args += ["-t", String(format: "%.6f", d)] }
            args += ["-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, levelURL.path]
            try await FFmpegRunner.run(exe: tools.ffmpeg, args: args)
            postLevelURL = levelURL
            try Task.checkCancellation()
        } else {
            postLevelURL = midURL
        }

        // Dynamic leveling (optional, dynaudnorm bidirectional)
        let postDynLevelURL: URL
        if settings.dynamicLevelingEnabled {
            let dynLevelURL = work.appendingPathComponent("\(stem)_dynleveled.wav")
            let dynFilter = dynamicLevelingFilter(amount: settings.dynamicLevelingAmount)
            onLog?("  dynamic leveling: \(dynFilter)", .verbose)
            var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", postLevelURL.path,
                        "-af", "apad=pad_dur=16,\(dynFilter)"]
            if let d = dynaudnormDuration { args += ["-t", String(format: "%.6f", d)] }
            args += ["-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, dynLevelURL.path]
            try await FFmpegRunner.run(exe: tools.ffmpeg, args: args)
            postDynLevelURL = dynLevelURL
            try Task.checkCancellation()
        } else {
            postDynLevelURL = postLevelURL
        }

        // Loudness normalization (optional, two-pass EBU R128)
        let limiterInput: URL
        if settings.loudnormEnabled {
            let target = settings.loudnormTarget
            let tp = settings.limitDb

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

        onLog?("  limiter: 2× oversample (\(oversampleSr) Hz)  |  ceiling \(settings.limitDb) dBTP  |  attack 5 ms  |  release 50 ms", .verbose)

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

    private func formatDbTag(_ db: Double) -> String {
        var s = String(format: "%.2f", db)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        return "\(s)dB"
    }

    // Maps 0.0 (gentle) → 1.0 (aggressive) to dynaudnorm parameters.
    // Shorter frames and tighter Gaussian smoothing = more responsive leveling.
    private func dynamicLevelingFilter(amount: Double) -> String {
        let f = Int(500.0 - amount * 350.0)         // frame ms: 500 → 150
        let gRaw = Int(31.0 - amount * 16.0)        // gaussian: 31 → 15
        let g = gRaw % 2 == 0 ? gRaw - 1 : gRaw    // must be odd
        let m = 2.0 + amount * 4.0                  // max gain factor: 2x → 6x (+6 to +15 dB)
        // t=0.05: silence threshold (~-26 dBFS). Frames below this peak magnitude
        // are not amplified — prevents boosting the noise floor between words on
        // sparse voice tracks. Note: dynaudnorm's `s` is compress, not threshold.
        return "dynaudnorm=f=\(f):g=\(g):p=0.95:m=\(String(format: "%.1f", m)):t=0.05"
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
