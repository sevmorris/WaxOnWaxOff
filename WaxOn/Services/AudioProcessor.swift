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

    init(settings: WaxOnSettings) {
        self.settings = settings
    }

    func run(inputs: [JobInput]) async throws -> [JobResult] {
        guard !inputs.isEmpty else { return [] }

        let tools = try await FFmpegManager.shared.ensureTools()
        var results: [JobResult] = []

        for input in inputs {
            try Task.checkCancellation()
            if let result = try await processOne(input.url, tools: tools) {
                results.append(JobResult(id: input.id, input: input.url, output: result.output))
            }
        }

        return results
    }

    private func processOne(_ input: URL, tools: FFmpegManager.Paths) async throws -> JobResult? {
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

        let phaseFilter = settings.phaseRotationEnabled ? "allpass=f=150:t=q:w=0.707," : ""

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
            let analyzeAf = "loudnorm=I=\(target):TP=-1:LRA=20:print_format=json"
            let analysisOutput = try await runFFmpegCapture(exe: tools.ffmpeg, args: [
                "-nostdin", "-hide_banner",
                "-i", midURL.path, "-af", analyzeAf,
                "-f", "null", "/dev/null"
            ])

            let stats = try parseLoudnormStats(analysisOutput)

            let normURL = work.appendingPathComponent("\(stem)_norm.wav")
            let normAf = "loudnorm=I=\(target):TP=-1:LRA=20:measured_I=\(stats.inputI):measured_TP=\(stats.inputTP):measured_LRA=\(stats.inputLRA):measured_thresh=\(stats.inputThresh):offset=\(stats.targetOffset):linear=true"

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

        var oversampleSr = sr
        if settings.truePeakEnabled {
            oversampleSr = sr * max(1, settings.truePeakOversample)
        }

        let step2Af = [
            "aresample=\(oversampleSr)",
            "alimiter=limit=\(limitAmp):attack=\(settings.attackMs):release=\(settings.releaseMs):level=disabled",
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

        return JobResult(input: input, output: finalURL)
    }

    private nonisolated func runFFmpeg(exe: String, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let fm = FileManager.default
            guard fm.fileExists(atPath: exe) else {
                continuation.resume(throwing: ProcessingError.ffmpegNotFound)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8) ?? ""
                let exitCode = proc.terminationStatus

                if exitCode != 0 {
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(code: exitCode, message: msg.isEmpty ? "Exit code \(exitCode)" : msg))
                } else {
                    continuation.resume(returning: ())
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessingError.ffmpegFailed(code: -1, message: "Failed to launch: \(error.localizedDescription)"))
            }
        }
    }

    private nonisolated func runFFmpegCapture(exe: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let fm = FileManager.default
            guard fm.fileExists(atPath: exe) else {
                continuation.resume(throwing: ProcessingError.ffmpegNotFound)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8) ?? ""
                let exitCode = proc.terminationStatus

                if exitCode != 0 {
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(code: exitCode, message: msg.isEmpty ? "Exit code \(exitCode)" : msg))
                } else {
                    continuation.resume(returning: msg)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessingError.ffmpegFailed(code: -1, message: "Failed to launch: \(error.localizedDescription)"))
            }
        }
    }

    private nonisolated func parseLoudnormStats(_ output: String) throws -> LoudnormStats {
        guard let jsonStart = output.range(of: "{", options: .backwards),
              let jsonEnd = output.range(of: "}", options: .backwards) else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse loudnorm analysis output")
        }

        let jsonStr = String(output[jsonStart.lowerBound...jsonEnd.upperBound])
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
        let here = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: here.path) { return here }

        let music = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music/WaxOn", isDirectory: true)
        if (try? fm.createDirectory(at: music, withIntermediateDirectories: true)) != nil {
            return music
        }

        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
