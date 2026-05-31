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
}

