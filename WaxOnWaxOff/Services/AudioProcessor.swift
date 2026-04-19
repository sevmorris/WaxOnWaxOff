import Foundation

struct JobInput: Sendable {
    let id: UUID
    let url: URL
}

private struct LoudnormStats {
    let inputI: String
    let inputTP: String
    let inputLRA: String
    let inputThresh: String
    let targetOffset: String
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
        let maxConcurrent = 3

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
        let dsTag = settings.deEsserEnabled ? "ds-" : ""
        let outName = "\(stem)-\(rateTag)\(dsTag)waxon-\(limitTag).wav"
        let finalURL = outDir.appendingPathComponent(outName)
        let tmpURL = outDir.appendingPathComponent(".\(outName).tmp")

        let work = try makeTemp(prefix: "waxon_\(rateTag)_")
        defer { try? fm.removeItem(at: work) }

        let isStereo = settings.outputChannels == .stereo
        let channelSuffix = isStereo ? "stereo" : "mono"
        let midURL = work.appendingPathComponent("\(stem)_\(rateTag)24_\(channelSuffix).wav")

        let phaseFilter = "allpass=f=200:t=q:w=0.707,"

        let nrEnabled = settings.noiseReductionEnabled
        let nrModelURL = nrEnabled
            ? Bundle.main.url(forResource: "rnnoise", withExtension: nil)
            : nil

        let outputChannelCount: String = isStereo ? "2" : "1"

        onLog?("▶ \(filename)", .info)
        let channelDesc = isStereo ? "stereo" : "mono (\(settings.channel.rawValue))"
        let nrDesc = nrEnabled ? "  |  RNNoise" : ""
        onLog?("  filter: highpass=\(settings.dcBlockHz) Hz  |  phase rotation: 200 Hz\(nrDesc)  |  \(channelDesc)  |  \(rateTag) kHz", .verbose)

        if isStereo, let modelURL = nrModelURL {
            // Split → denoise each channel independently → rejoin, then
            // highpass + phase rotation + resample.
            let escapedModel = ffmpegFilterEscape(modelURL.path)
            let fc = [
                "[0:a]channelsplit=channel_layout=stereo[L][R]",
                "[L]arnndn=m=\(escapedModel)[Lnr]",
                "[R]arnndn=m=\(escapedModel)[Rnr]",
                "[Lnr][Rnr]join=inputs=2:channel_layout=stereo,",
                "highpass=f=\(settings.dcBlockHz),\(phaseFilter)aresample=\(sr)"
            ].joined(separator: ";")
            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", input.path, "-filter_complex", fc,
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, midURL.path
            ])
        } else {
            // Mono output, or no NR — simple -af chain
            var nrPrefix = ""
            if let modelURL = nrModelURL {
                nrPrefix = "arnndn=m=\(ffmpegFilterEscape(modelURL.path)),"
            }
            let step1Af: String
            if isStereo {
                step1Af = "highpass=f=\(settings.dcBlockHz),\(phaseFilter)aresample=\(sr)"
            } else {
                let pan = settings.channel == .left ? "pan=1c|c0=c0" : "pan=1c|c0=c1"
                step1Af = "\(nrPrefix)highpass=f=\(settings.dcBlockHz),\(pan),\(phaseFilter)aresample=\(sr)"
            }
            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", input.path, "-af", step1Af,
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, midURL.path
            ])
        }

        try Task.checkCancellation()

        // De-esser (optional)
        let postDsURL: URL
        if settings.deEsserEnabled {
            let dsURL = work.appendingPathComponent("\(stem)_ds.wav")
            onLog?("  de-esser: deesser 7.5 kHz", .verbose)
            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", midURL.path, "-af", "deesser=i=0.3:f=0.34:s=o",
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, dsURL.path
            ])
            postDsURL = dsURL
            try Task.checkCancellation()
        } else {
            postDsURL = midURL
        }

        // Level riding (optional, dynaudnorm downward-only)
        let postLevelURL: URL
        if settings.levelRidingEnabled {
            let levelURL = work.appendingPathComponent("\(stem)_leveled.wav")
            onLog?("  level riding: dynaudnorm (downward only, no boost)", .verbose)
            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", postDsURL.path, "-af", "dynaudnorm=p=0.95:m=1.0:g=31",
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, levelURL.path
            ])
            postLevelURL = levelURL
            try Task.checkCancellation()
        } else {
            postLevelURL = postDsURL
        }

        // Dynamic leveling (optional, dynaudnorm bidirectional)
        let postDynLevelURL: URL
        if settings.dynamicLevelingEnabled {
            let dynLevelURL = work.appendingPathComponent("\(stem)_dynleveled.wav")
            let filter = dynamicLevelingFilter(amount: settings.dynamicLevelingAmount)
            onLog?("  dynamic leveling: \(filter)", .verbose)
            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", postLevelURL.path, "-af", filter,
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, dynLevelURL.path
            ])
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

            // When NR is off, run RNNoise on a temp copy for the analysis pass only.
            // This prevents broadband noise from inflating the loudness measurement,
            // ensuring speech hits the target LUFS more accurately.
            let analysisInput: URL
            if !settings.noiseReductionEnabled,
               let modelURL = Bundle.main.url(forResource: "rnnoise", withExtension: nil) {
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
                    try await runFFmpeg(exe: tools.ffmpeg, args: [
                        "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", postDynLevelURL.path, "-filter_complex", nrFc,
                        "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, nrTempURL.path
                    ])
                } else {
                    try await runFFmpeg(exe: tools.ffmpeg, args: [
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
            let analysisOutput = try await runFFmpegCapture(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner",
                "-i", analysisInput.path, "-af", analyzeAf,
                "-f", "null", "/dev/null"
            ])

            let stats = try parseLoudnormStats(analysisOutput)
            onLog?("  measured: \(stats.inputI) LUFS  |  TP \(stats.inputTP) dBTP  |  LRA \(stats.inputLRA) LU", .info)
            onLog?("  target: \(target) LUFS  |  offset \(stats.targetOffset) dB  |  thresh \(stats.inputThresh) LUFS", .verbose)
            onLog?("  loudnorm: normalizing…", .verbose)

            let normURL = work.appendingPathComponent("\(stem)_norm.wav")
            let normAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:measured_I=\(stats.inputI):measured_TP=\(stats.inputTP):measured_LRA=\(stats.inputLRA):measured_thresh=\(stats.inputThresh):offset=\(stats.targetOffset):linear=true"

            try await runFFmpeg(exe: tools.ffmpeg, args: [
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

        try await runFFmpeg(exe: tools.ffmpeg, args: [
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

    private nonisolated func runFFmpeg(exe: String, args: [String]) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: exe) else {
            throw ProcessingError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        // MEDIUM-3: DataBox avoids nonisolated(unsafe) var across closure boundaries
        final class DataBox: @unchecked Sendable { var value = Data() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe

                let box = DataBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                // MEDIUM-5: terminate after 15 minutes to prevent infinite hangs
                let timeoutItem = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 900, execute: timeoutItem)

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    readGroup.wait()
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let exitCode = proc.terminationStatus
                    let msg = String(data: box.value, encoding: .utf8) ?? ""
                    if exitCode == 0 {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(code: exitCode, message: msg.isEmpty ? "Exit code \(exitCode)" : msg))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(code: -1, message: "Failed to launch: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private nonisolated func runFFmpegCapture(exe: String, args: [String]) async throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: exe) else {
            throw ProcessingError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        final class DataBox: @unchecked Sendable { var value = Data() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe

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
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let exitCode = proc.terminationStatus
                    let msg = String(data: box.value, encoding: .utf8) ?? ""
                    if exitCode == 0 {
                        continuation.resume(returning: msg)
                    } else {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(code: exitCode, message: msg.isEmpty ? "Exit code \(exitCode)" : msg))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(code: -1, message: "Failed to launch: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private nonisolated func parseLoudnormStats(_ output: String) throws -> LoudnormStats {
        // Find the last '{' (start of the JSON block), then scan forward to its matching '}'
        guard let braceRange = output.range(of: "{", options: .backwards) else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse loudnorm analysis output")
        }

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

        guard let jsonEnd else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse loudnorm analysis output")
        }

        let jsonStr = String(output[braceRange.lowerBound...jsonEnd])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: String] else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Invalid loudnorm JSON output")
        }

        guard let inputI = dict["input_i"],
              let inputTP = dict["input_tp"],
              let inputLRA = dict["input_lra"],
              let inputThresh = dict["input_thresh"],
              let targetOffset = dict["target_offset"] else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Missing loudnorm measurement fields")
        }

        return LoudnormStats(
            inputI: inputI,
            inputTP: inputTP,
            inputLRA: inputLRA,
            inputThresh: inputThresh,
            targetOffset: targetOffset
        )
    }

    private func makeTemp(prefix: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
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
        let f = Int(750.0 - amount * 600.0)         // frame ms: 750 → 150
        let gRaw = Int(31.0 - amount * 24.0)        // gaussian: 31 → 7
        let g = gRaw % 2 == 0 ? gRaw - 1 : gRaw    // must be odd
        let m = 8.0 + amount * 12.0                 // max gain factor: 8x → 20x
        return "dynaudnorm=f=\(f):g=\(g):r=1:p=0.95:m=\(String(format: "%.1f", m)):n=1:b=1"
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
