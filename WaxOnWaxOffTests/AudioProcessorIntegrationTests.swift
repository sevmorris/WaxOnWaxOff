import XCTest
@testable import WaxOnWaxOff

/// FFmpeg integration tests — require bundled binaries (run `./scripts/fetch-ffmpeg.sh` first).
final class AudioProcessorIntegrationTests: XCTestCase {

    private var tools: FFmpegManager.Paths?
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tools = try IntegrationFFmpeg.locate()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    func testWaxOnProducesNonEmptyWAV() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "input.wav",
            durationSeconds: 0.5,
            sampleRate: 44100
        )

        var settings = WaxOnSettings()
        settings.loudnormEnabled = false
        settings.highPassEnabled = true
        settings.phaseRotationEnabled = true
        settings.outputChannels = .mono

        let processor = AudioProcessor(settings: settings)
        let batch = try await processor.run(inputs: [JobInput(id: UUID(), url: input)])

        XCTAssertEqual(batch.failures.count, 0, batch.failures.map(\.message).joined(separator: "; "))
        let result = try XCTUnwrap(batch.successes.first)
        let attrs = try FileManager.default.attributesOfItem(atPath: result.output.path)
        let size = try XCTUnwrap(attrs[.size] as? NSNumber)
        XCTAssertGreaterThan(size.intValue, 1000)
    }

    func testLoudnormEnabledAt44100() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "loudnorm_input.wav",
            durationSeconds: 1.0,
            sampleRate: 44100
        )

        var settings = WaxOnSettings()
        settings.sampleRate = .s44100
        settings.loudnormEnabled = true
        settings.loudnormTarget = -30.0
        settings.outputChannels = .mono

        let processor = AudioProcessor(settings: settings)
        let batch = try await processor.run(inputs: [JobInput(id: UUID(), url: input)])

        XCTAssertEqual(batch.failures.count, 0, batch.failures.map(\.message).joined(separator: "; "))
        XCTAssertEqual(batch.successes.count, 1)
    }

    func testWaxOnLoudnormAt48kHzHitsTarget() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "loudnorm_48k_in.wav",
            durationSeconds: 6.0,
            sampleRate: 48000
        )

        var settings = WaxOnSettings()
        settings.sampleRate = .s48000
        settings.loudnormEnabled = true
        settings.loudnormTarget = -23.0
        settings.phaseRotationEnabled = false
        settings.outputChannels = .mono
        settings.outputDirectoryPath = workDir.path

        let processor = AudioProcessor(settings: settings)
        let batch = try await processor.run(inputs: [JobInput(id: UUID(), url: input)])
        XCTAssertEqual(batch.failures.count, 0, batch.failures.map(\.message).joined(separator: "; "))
        let output = try XCTUnwrap(batch.successes.first?.output)

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: output)
        // Prep chain includes HPF + limiter; allow wider tolerance than WaxOff delivery.
        XCTAssertEqual(measuredI, settings.loudnormTarget, accuracy: 2.0)
    }

    /// Loudness Norm ON now fuses the pass-2 linear normalize and the limiter into a
    /// single filter chain (no intermediate `_norm.wav`). This pins that the fusion is
    /// loudness-equivalent to the prior two-process approach by running BOTH on the same
    /// measured values and asserting they match within 0.1 dB on integrated loudness and
    /// true peak — using the production filter builders (`linearPassFilter`, the limiter
    /// chain), and bypassing the NR-for-measurement pass whose suppression of a pure tone
    /// would otherwise confound a "hits target" assertion. The AudioProcessor end-to-end
    /// wiring of the fused path is exercised separately by `testWaxOnLoudnormAt48kHzHitsTarget`.
    func testFusedLoudnormLimiterEquivalentToTwoProcess() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "fuse_eq_in.wav",
            durationSeconds: 5.0,
            sampleRate: 44100
        )

        // Pass-1 analysis → measured values (same capture + parse path AudioProcessor uses).
        let analysisStderr = try await FFmpegRunner.capture(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner",
            "-i", input.path, "-af", "loudnorm=I=-23:TP=-1.0:LRA=20:print_format=json",
            "-f", "null", "/dev/null"
        ])
        let dict = try XCTUnwrap(FFmpegRunner.parseLoudnormJSON(from: analysisStderr))
        let measurements = try XCTUnwrap(LoudnormMeasurements(json: dict.mapValues { $0 as Any }))
        try XCTSkipIf(!measurements.isFinite, "analysis produced non-finite measurements")

        // Same filter fragments AudioProcessor builds on the loudnorm-on path.
        let normAf = measurements.linearPassFilter(targetLUFS: -23, truePeakDB: -1.0, lra: 20)
        let limiterAf = [
            FFmpegFilters.aresample(to: 44100 * 2),
            "alimiter=limit=\(FFmpegFilters.limiterCeilingAmplitude(dBFS: -1.0)):attack=5:release=50:level=disabled",
            FFmpegFilters.aresample(to: 44100)
        ].joined(separator: ",")

        // Prior two-process approach: normalize → intermediate, then limit the intermediate.
        let normURL = workDir.appendingPathComponent("two_norm.wav")
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", input.path, "-af", normAf,
            "-c:a", "pcm_s24le", "-ar", "44100", "-ac", "1", normURL.path
        ])
        let twoProcessURL = workDir.appendingPathComponent("two_out.wav")
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", normURL.path, "-af", limiterAf,
            "-map_metadata", "0", "-c:a", "pcm_s24le", "-ar", "44100", "-ac", "1", "-f", "wav", twoProcessURL.path
        ])

        // Fused approach: one process, loudnorm + limiter in a single -af chain.
        let fusedURL = workDir.appendingPathComponent("fused_out.wav")
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", input.path, "-af", "\(normAf),\(limiterAf)",
            "-map_metadata", "0", "-c:a", "pcm_s24le", "-ar", "44100", "-ac", "1", "-f", "wav", fusedURL.path
        ])

        let twoI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: twoProcessURL)
        let fusedI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: fusedURL)
        let twoTP = try await measureTruePeak(ffmpeg: tools.ffmpeg, of: twoProcessURL)
        let fusedTP = try await measureTruePeak(ffmpeg: tools.ffmpeg, of: fusedURL)

        // The fusion must not change the result.
        XCTAssertEqual(fusedI, twoI, accuracy: 0.1,
                       "fused integrated loudness must match the two-process approach")
        XCTAssertEqual(fusedTP, twoTP, accuracy: 0.1,
                       "fused true peak must match the two-process approach")
        // And both must land on target / under ceiling (no NR confound on this raw path).
        XCTAssertEqual(fusedI, -23.0, accuracy: 0.3, "fused output should hit the loudnorm target")
        XCTAssertLessThanOrEqual(fusedTP, -1.0 + 0.1, "fused output must honor the −1.0 dBTP ceiling")
    }

    // MARK: - Loudness Norm OFF: linear peak-normalize (attenuate-only)
    func testLoudnormOffHotSourceLinearlyNormalizedToCeiling() async throws {
        let tools = try XCTUnwrap(tools)
        // 440 Hz sine pushed to ~0 dBFS (lavfi `sine` is ~−18 dBFS on its own) so
        // its true peak sits above the −1.0 ceiling and a gain must be applied.
        let input = workDir.appendingPathComponent("wax_on_hot.wav")
        try IntegrationFFmpeg.run(ffmpeg: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-af", "volume=18dB",
            "-ar", "44100", "-ac", "1", "-c:a", "pcm_s16le",
            input.path
        ])

        var settings = WaxOnSettings()
        settings.sampleRate = .s44100
        settings.loudnormEnabled = false
        settings.highPassEnabled = false        // highpass=20 is transparent at 440 Hz
        settings.phaseRotationEnabled = false
        settings.dynamicLevelingEnabled = false
        settings.outputChannels = .mono
        settings.outputDirectoryPath = workDir.path

        let collector = LogCollector()
        let processor = AudioProcessor(settings: settings, onLog: { collector.append($0, $1) })
        let batch = try await processor.run(inputs: [JobInput(id: UUID(), url: input)])
        XCTAssertEqual(batch.failures.count, 0, batch.failures.map(\.message).joined(separator: "; "))
        let output = try XCTUnwrap(batch.successes.first?.output)

        // The attenuate-only linear path ran — not the brick-wall limiter.
        XCTAssertTrue(collector.infoMessages.contains { $0.contains("linear gain") && $0.contains("no limiting") },
                      "expected the linear-gain log line, not the limiter")

        // Lands at or below the −1.0 dBTP ceiling.
        let outTP = try await measureTruePeak(ffmpeg: tools.ffmpeg, of: output)
        XCTAssertLessThanOrEqual(outTP, -1.0 + 0.3, "output true peak should sit at or below the −1.0 dBTP ceiling")

        // Uniform gain: peak and RMS drop by the same amount. A limiter would pull
        // the peak down far more than the RMS.
        let (inPeak, inRMS) = try await measurePeakRMS(ffmpeg: tools.ffmpeg, of: input)
        let (outPeak, outRMS) = try await measurePeakRMS(ffmpeg: tools.ffmpeg, of: output)
        let peakReduction = inPeak - outPeak
        let rmsReduction = inRMS - outRMS
        XCTAssertGreaterThan(peakReduction, 0.3, "a hotter-than-ceiling source must be attenuated")
        XCTAssertEqual(peakReduction, rmsReduction, accuracy: 0.3,
                       "reduction must be uniform (linear gain), not limiting")
    }

    /// A source already within the −1.0 dBTP ceiling passes through with no gain:
    /// peak and RMS are unchanged.
    func testLoudnormOffWithinCeilingPassesThroughUnchanged() async throws {
        let tools = try XCTUnwrap(tools)
        // Plain ~−18 dBFS 440 Hz sine → true peak well within the −1.0 ceiling.
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_on_quiet.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOnSettings()
        settings.sampleRate = .s44100
        settings.loudnormEnabled = false
        settings.highPassEnabled = false
        settings.phaseRotationEnabled = false
        settings.dynamicLevelingEnabled = false
        settings.outputChannels = .mono
        settings.outputDirectoryPath = workDir.path

        let collector = LogCollector()
        let processor = AudioProcessor(settings: settings, onLog: { collector.append($0, $1) })
        let batch = try await processor.run(inputs: [JobInput(id: UUID(), url: input)])
        XCTAssertEqual(batch.failures.count, 0, batch.failures.map(\.message).joined(separator: "; "))
        let output = try XCTUnwrap(batch.successes.first?.output)

        // The within-ceiling pass-through branch ran (gain 0).
        XCTAssertTrue(collector.infoMessages.contains { $0.contains("passed through unmodified") },
                      "expected the within-ceiling pass-through log line")

        // No attenuation: output peak/RMS match the input.
        let (inPeak, inRMS) = try await measurePeakRMS(ffmpeg: tools.ffmpeg, of: input)
        let (outPeak, outRMS) = try await measurePeakRMS(ffmpeg: tools.ffmpeg, of: output)
        XCTAssertEqual(outPeak, inPeak, accuracy: 0.3, "within-ceiling source should not be attenuated")
        XCTAssertEqual(outRMS, inRMS, accuracy: 0.3, "within-ceiling source should not be attenuated")
    }

    /// A >2-channel source under Stereo output is folded to two channels by
    /// FFmpeg's default matrix. That is channel-destructive and must be
    /// announced, exactly as the mono path already announces its equivalent.
    func testMultichannelSourceUnderStereoOutputLogsWarning() async throws {
        let tools = try XCTUnwrap(tools)

        let input = workDir.appendingPathComponent("wax_on_5p1.wav")
        try IntegrationFFmpeg.run(ffmpeg: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-af", "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0",
            "-ar", "44100", "-c:a", "pcm_s16le",
            input.path
        ])
        let inputChannels = try await channelCount(ffprobe: tools.ffprobe, of: input)
        XCTAssertEqual(inputChannels, 6,
                       "fixture must actually be 6-channel for this test to mean anything")

        var settings = WaxOnSettings()
        settings.sampleRate = .s44100
        settings.outputChannels = .stereo
        settings.loudnormEnabled = false
        settings.dynamicLevelingEnabled = false
        settings.outputDirectoryPath = workDir.path

        let collector = LogCollector()
        let processor = AudioProcessor(settings: settings, onLog: { collector.append($0, $1) })
        let batch = try await processor.run(inputs: [JobInput(id: UUID(), url: input)])
        XCTAssertEqual(batch.failures.count, 0, batch.failures.map(\.message).joined(separator: "; "))

        XCTAssertTrue(collector.infoMessages.contains { $0.contains("6-channel input") && $0.contains("downmixing to stereo") },
                      "expected a downmix warning for a 6-channel source under Stereo output; got: \(collector.infoMessages)")

        let output = try XCTUnwrap(batch.successes.first?.output)
        let outputChannels = try await channelCount(ffprobe: tools.ffprobe, of: output)
        XCTAssertEqual(outputChannels, 2,
                       "stereo output should be 2-channel")
    }

    // MARK: -

    /// Channel count of audio stream a:0 via ffprobe.
    private func channelCount(ffprobe: String, of url: URL) async throws -> Int {
        let out = try await FFmpegRunner.captureStdout(exe: ffprobe, args: [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=channels", "-of", "default=nw=1:nk=1", url.path
        ])
        return try XCTUnwrap(Int(out.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func measureIntegratedLoudness(ffmpeg: String, of url: URL) async throws -> Double {
        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: [
            "-nostdin", "-hide_banner",
            "-i", url.path,
            "-af", "loudnorm=I=-23:TP=-1:LRA=20:print_format=json",
            "-f", "null", "/dev/null"
        ])
        let dict = try XCTUnwrap(FFmpegRunner.parseLoudnormJSON(from: stderr))
        return try XCTUnwrap(Double(dict["input_i"] ?? ""))
    }

    /// Re-measures the true peak (loudnorm input_tp) of a file.
    private func measureTruePeak(ffmpeg: String, of url: URL) async throws -> Double {
        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: [
            "-nostdin", "-hide_banner",
            "-i", url.path,
            "-af", "loudnorm=I=-23:TP=-1:LRA=20:print_format=json",
            "-f", "null", "/dev/null"
        ])
        let dict = try XCTUnwrap(FFmpegRunner.parseLoudnormJSON(from: stderr))
        return try XCTUnwrap(Double(dict["input_tp"] ?? ""))
    }

    /// Returns volumedetect's max_volume (sample peak) and mean_volume (RMS), in dBFS.
    /// The first 0.5 s is trimmed so the mandatory 20 Hz high-pass's one-off startup
    /// transient (~0.5 dB peak overshoot) doesn't skew the steady-state reading.
    private func measurePeakRMS(ffmpeg: String, of url: URL) async throws -> (peak: Double, rms: Double) {
        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: [
            "-nostdin", "-hide_banner",
            "-i", url.path, "-af", "atrim=start=0.5,volumedetect",
            "-f", "null", "/dev/null"
        ])
        let peak = try XCTUnwrap(Self.parseVolumeDetectDB(label: "max_volume:", in: stderr),
                                 "volumedetect did not report max_volume")
        let rms = try XCTUnwrap(Self.parseVolumeDetectDB(label: "mean_volume:", in: stderr),
                                "volumedetect did not report mean_volume")
        return (peak, rms)
    }

    private static func parseVolumeDetectDB(label: String, in text: String) -> Double? {
        guard let labelRange = text.range(of: label) else { return nil }
        let tail = text[labelRange.upperBound...]
        guard let dbRange = tail.range(of: "dB") else { return nil }
        let number = tail[tail.startIndex..<dbRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(number)
    }
}

/// Thread-safe sink for the `onLog` callback, which fires from the processor's
/// concurrency domain. Lets a test collect log lines and inspect them after the
/// awaited run completes.
nonisolated private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(message: String, level: LogLevel)] = []

    func append(_ message: String, _ level: LogLevel) {
        lock.lock(); defer { lock.unlock() }
        lines.append((message, level))
    }

    var infoMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { line in
            if case .info = line.level { return line.message }
            return nil
        }
    }

    var verboseMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { line in
            if case .verbose = line.level { return line.message }
            return nil
        }
    }
}

