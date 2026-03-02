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

    init(settings: WaxOnSettings, onFileStarted: (@Sendable (UUID) -> Void)? = nil) {
        self.settings = settings
        self.onFileStarted = onFileStarted
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
                    await self.onFileStarted?(input.id)
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

    func mixAndProcess(inputs: [URL], onPhase: (@Sendable (String) -> Void)? = nil) async throws -> JobResult {
        guard !inputs.isEmpty else { throw ProcessingError.invalidInput }
        let fm = FileManager.default
        for url in inputs {
            guard fm.fileExists(atPath: url.path) else { throw ProcessingError.invalidInput }
        }

        let tools = try await FFmpegManager.shared.ensureTools()
        let sr = settings.sampleRate.rawValue
        let rateTag = sr == 44100 ? "44k" : "48k"
        let limitAmp = pow(10.0, settings.limitDb / 20.0)
        let limitTag = formatDbTag(settings.limitDb)
        let outDir = bestOutputDir(for: inputs[0])
        let n = inputs.count
        let outName = "mix-\(rateTag)waxon-\(limitTag).wav"
        let finalURL = outDir.appendingPathComponent(outName)
        let tmpURL = outDir.appendingPathComponent(".\(outName).tmp")

        let work = try makeTemp(prefix: "waxon_mix_\(rateTag)_")
        defer { try? fm.removeItem(at: work) }

        // Step 0: amix N inputs → rawMix.wav
        onPhase?("Mixing \(n) files…")
        let rawMixURL = work.appendingPathComponent("rawMix.wav")
        var amixArgs = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        for url in inputs {
            amixArgs += ["-i", url.path]
        }
        amixArgs += [
            "-filter_complex", "amix=inputs=\(n):duration=longest:normalize=1",
            "-c:a", "pcm_s24le", "-ar", "\(sr)", rawMixURL.path
        ]
        try await runFFmpeg(exe: tools.ffmpeg, args: amixArgs)
        try Task.checkCancellation()

        // Step 1: Highpass + phase rotation + channel selection + resample
        onPhase?("Filtering…")
        let isStereo = settings.outputChannels == .stereo
        let outputChannelCount = isStereo ? "2" : "1"
        let phaseFilter = "allpass=f=200:t=q:w=0.707,"
        let midURL = work.appendingPathComponent("mix_mid.wav")

        let step1Af: String
        if isStereo {
            step1Af = "highpass=f=\(settings.dcBlockHz),\(phaseFilter)aresample=\(sr)"
        } else {
            let pan = settings.channel == .left ? "pan=1c|c0=c0" : "pan=1c|c0=c1"
            step1Af = "highpass=f=\(settings.dcBlockHz),\(pan),\(phaseFilter)aresample=\(sr)"
        }

        try await runFFmpeg(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", rawMixURL.path, "-af", step1Af,
            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, midURL.path
        ])
        try Task.checkCancellation()

        // Step 2: Optional EBU R128 two-pass loudnorm
        let limiterInput: URL
        if settings.loudnormEnabled {
            let target = settings.loudnormTarget
            let tp = settings.limitDb
            onPhase?("Analyzing loudness…")
            let analyzeAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:print_format=json"
            let analysisOutput = try await runFFmpegCapture(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner",
                "-i", midURL.path, "-af", analyzeAf,
                "-f", "null", "/dev/null"
            ])

            let stats = try parseLoudnormStats(analysisOutput)

            onPhase?("Normalizing…")
            let normURL = work.appendingPathComponent("mix_norm.wav")
            let normAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:measured_I=\(stats.inputI):measured_TP=\(stats.inputTP):measured_LRA=\(stats.inputLRA):measured_thresh=\(stats.inputThresh):offset=\(stats.targetOffset):linear=true"

            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", midURL.path, "-af", normAf,
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, normURL.path
            ])

            limiterInput = normURL
        } else {
            limiterInput = midURL
        }
        try Task.checkCancellation()

        // Step 3: 2× oversample → brick-wall limiter → resample → final output
        onPhase?("Limiting…")
        let oversampleSr = sr * 2
        let step3Af = [
            "aresample=\(oversampleSr)",
            "alimiter=limit=\(limitAmp):attack=5:release=50:level=disabled",
            "aresample=\(sr)"
        ].joined(separator: ",")

        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        try await runFFmpeg(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", limiterInput.path, "-af", step3Af,
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

        return JobResult(id: nil, input: inputs[0], output: finalURL)
    }

    private func processOne(_ input: URL, id: UUID, tools: FFmpegManager.Paths) async throws -> JobResult? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else {
            throw ProcessingError.invalidInput
        }

        let sr = settings.sampleRate.rawValue
        let rateTag = sr == 44100 ? "44k" : "48k"
        let stem = input.deletingPathExtension().lastPathComponent
        let limitAmp = pow(10.0, settings.limitDb / 20.0)
        let limitTag = formatDbTag(settings.limitDb)
        let outDir = bestOutputDir(for: input)
        let outName = "\(stem)-\(rateTag)waxon-\(limitTag).wav"
        let finalURL = outDir.appendingPathComponent(outName)
        let tmpURL = outDir.appendingPathComponent(".\(outName).tmp")

        let work = try makeTemp(prefix: "waxon_\(rateTag)_")
        defer { try? fm.removeItem(at: work) }

        let isStereo = settings.outputChannels == .stereo
        let channelSuffix = isStereo ? "stereo" : "mono"
        let midURL = work.appendingPathComponent("\(stem)_\(rateTag)24_\(channelSuffix).wav")

        let phaseFilter = "allpass=f=200:t=q:w=0.707,"

        let step1Af: String
        let outputChannelCount: String
        if isStereo {
            step1Af = "highpass=f=\(settings.dcBlockHz),\(phaseFilter)aresample=\(sr)"
            outputChannelCount = "2"
        } else {
            let pan = settings.channel == .left ? "pan=1c|c0=c0" : "pan=1c|c0=c1"
            step1Af = "highpass=f=\(settings.dcBlockHz),\(pan),\(phaseFilter)aresample=\(sr)"
            outputChannelCount = "1"
        }

        try await runFFmpeg(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", input.path, "-af", step1Af,
            "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, midURL.path
        ])

        try Task.checkCancellation()

        // Loudness normalization (optional, two-pass EBU R128)
        let limiterInput: URL
        if settings.loudnormEnabled {
            let target = settings.loudnormTarget
            let tp = settings.limitDb
            let analyzeAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:print_format=json"
            let analysisOutput = try await runFFmpegCapture(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner",
                "-i", midURL.path, "-af", analyzeAf,
                "-f", "null", "/dev/null"
            ])

            let stats = try parseLoudnormStats(analysisOutput)

            let normURL = work.appendingPathComponent("\(stem)_norm.wav")
            let normAf = "loudnorm=I=\(target):TP=\(tp):LRA=20:measured_I=\(stats.inputI):measured_TP=\(stats.inputTP):measured_LRA=\(stats.inputLRA):measured_thresh=\(stats.inputThresh):offset=\(stats.targetOffset):linear=true"

            try await runFFmpeg(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", midURL.path, "-af", normAf,
                "-c:a", "pcm_s24le", "-ar", "\(sr)", "-ac", outputChannelCount, normURL.path
            ])

            limiterInput = normURL
        } else {
            limiterInput = midURL
        }

        try Task.checkCancellation()

        let oversampleSr = sr * 2

        let step2Af = [
            "aresample=\(oversampleSr)",
            "alimiter=limit=\(limitAmp):attack=5:release=50:level=disabled",
            "aresample=\(sr)"
        ].joined(separator: ",")

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

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe

                // Read pipe on GCD to avoid blocking the cooperative thread pool
                var stderrData = Data()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                process.terminationHandler = { proc in
                    readGroup.wait()
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let exitCode = proc.terminationStatus
                    let msg = String(data: stderrData, encoding: .utf8) ?? ""
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe

                // Read pipe on GCD to avoid blocking the cooperative thread pool
                var stderrData = Data()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                process.terminationHandler = { proc in
                    readGroup.wait()
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let exitCode = proc.terminationStatus
                    let msg = String(data: stderrData, encoding: .utf8) ?? ""
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

    private func formatDbTag(_ db: Double) -> String {
        var s = String(format: "%.2f", db)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        return "\(s)dB"
    }

    private func bestOutputDir(for input: URL) -> URL {
        let fm = FileManager.default

        // Use custom output directory if set
        if let customPath = settings.outputDirectoryPath {
            let customURL = URL(fileURLWithPath: customPath, isDirectory: true)
            if fm.isWritableFile(atPath: customURL.path) { return customURL }
        }

        let here = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: here.path) { return here }

        let music = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music/WaxOn", isDirectory: true)
        if (try? fm.createDirectory(at: music, withIntermediateDirectories: true)) != nil {
            return music
        }

        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
