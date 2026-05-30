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
}

// MARK: -

private enum IntegrationFFmpeg {
    static func locate() throws -> FFmpegManager.Paths {
        let root = projectRoot()
        let ffmpeg = root.appendingPathComponent("WaxOnWaxOff/ffmpeg")
        let ffprobe = root.appendingPathComponent("WaxOnWaxOff/ffprobe")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ffmpeg.path),
              fm.isExecutableFile(atPath: ffprobe.path) else {
            throw XCTSkip("FFmpeg binaries missing — run ./scripts/fetch-ffmpeg.sh")
        }
        return FFmpegManager.Paths(ffmpeg: ffmpeg.path, ffprobe: ffprobe.path)
    }

    static func makeSineWAV(
        ffmpeg: String,
        directory: URL,
        name: String,
        durationSeconds: Double,
        sampleRate: Int
    ) throws -> URL {
        let out = directory.appendingPathComponent(name)
        try run(ffmpeg: ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(durationSeconds)",
            "-ar", "\(sampleRate)", "-ac", "1",
            "-c:a", "pcm_s16le",
            out.path
        ])
        return out
    }

    private static func run(ffmpeg: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "IntegrationFFmpeg", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: msg.isEmpty ? "ffmpeg exit \(process.terminationStatus)" : msg
            ])
        }
    }

    private static func projectRoot() -> URL {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDir.deletingLastPathComponent()
    }
}
