import XCTest
@testable import WaxOnWaxOff

/// End-to-end WaxOff tests — drive `DeliveryProcessor.process` against a
/// generated input, then re-measure the rendered output with loudnorm to
/// verify the configured target was actually reached. Requires the bundled
/// FFmpeg binaries (see `scripts/fetch-ffmpeg.sh`).
final class DeliveryProcessorIntegrationTests: XCTestCase {

    private var tools: FFmpegManager.Paths?
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tools = try IntegrationFFmpeg.locate()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// Rendered WAV should land within ±1 LU of the configured target. Catches
    /// regressions in the two-pass loudnorm wiring (analyze → render with
    /// measured values injected) and in the post-loudnorm limiter stage.
    func testWaxOffWAVHitsTargetLUFS() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_in.wav",
            durationSeconds: 6.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -23.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.outputDirectoryPath = workDir.path

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: wav)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.0,
                       "WaxOff WAV output should sit within ±1 LU of the configured target")
    }

    /// "Both" output produces a WAV and an MP3 derived from it. Verifies both
    /// files exist and that the WAV side still hits target — the MP3 path
    /// re-runs the input through its own pre-encode limiter, so a regression
    /// there shouldn't poison the WAV measurement.
    func testWaxOffBothModeProducesWAVAndMP3() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_both.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(outputs.contains(where: { $0.pathExtension == "wav" }))
        XCTAssertTrue(outputs.contains(where: { $0.pathExtension == "mp3" }))

        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))
        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: wav)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.0)
    }

    func testWaxOffMP3HitsTargetLUFS() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_mp3_in.wav",
            durationSeconds: 6.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .mp3
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: mp3)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.5,
                       "MP3 encode may drift slightly from WAV; allow wider tolerance")
    }

    // MARK: -

    /// Re-runs loudnorm pass-1 analysis on the given file and returns the
    /// integrated-loudness reading. Same parsing path the processor uses, so
    /// any drift in JSON handling shows up here too.
    private func measureIntegratedLoudness(ffmpeg: String, of url: URL) async throws -> Double {
        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: [
            "-nostdin", "-hide_banner",
            "-i", url.path,
            "-af", "loudnorm=I=-23:TP=-1:LRA=9:print_format=json",
            "-f", "null", "/dev/null"
        ])
        let dict = try XCTUnwrap(FFmpegRunner.parseLoudnormJSON(from: stderr))
        let inputI = try XCTUnwrap(dict["input_i"])
        return try XCTUnwrap(Double(inputI))
    }
}
