import XCTest
@testable import WaxOnWaxOff

final class AudioStreamProbeTests: XCTestCase {
    private var tools: FFmpegManager.Paths?
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tools = try IntegrationFFmpeg.locate()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    func testHasAudioStreamOnWAV() async throws {
        let tools = try XCTUnwrap(tools)
        let wav = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "probe.wav",
            durationSeconds: 0.25,
            sampleRate: 44100
        )
        let ok = await AudioStreamProbe.hasAudioStream(ffprobe: tools.ffprobe, url: wav)
        XCTAssertTrue(ok)
    }

    func testHasAudioStreamRejectsTextFile() async throws {
        let tools = try XCTUnwrap(tools)
        let txt = workDir.appendingPathComponent("not-audio.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        let ok = await AudioStreamProbe.hasAudioStream(ffprobe: tools.ffprobe, url: txt)
        XCTAssertFalse(ok)
    }
}
