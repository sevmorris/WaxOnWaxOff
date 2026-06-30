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

    func testLoudnormTwoPassAt44100WithNRPath() async throws {
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

    // MARK: - Loudness Norm OFF: linear peak-normalize (attenuate-only)

    /// With Loudness Norm off, a source hotter than −1.0 dBTP is brought to the
    /// ceiling by a single uniform linear gain (not the limiter): the peak and the
    /// RMS drop by the same amount.
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

    // MARK: -

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
private final class LogCollector: @unchecked Sendable {
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
}

