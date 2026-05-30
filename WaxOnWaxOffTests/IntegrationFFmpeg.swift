import Foundation
import XCTest
@testable import WaxOnWaxOff

/// Shared FFmpeg-binary helpers for integration tests. The bundled binaries
/// live next to the project source and are fetched by
/// `scripts/fetch-ffmpeg.sh`; tests `XCTSkip` cleanly when they're absent so
/// suites still run on machines that haven't fetched them.
enum IntegrationFFmpeg {
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
        sampleRate: Int,
        channels: Int = 1
    ) throws -> URL {
        let out = directory.appendingPathComponent(name)
        try run(ffmpeg: ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(durationSeconds)",
            "-ar", "\(sampleRate)", "-ac", "\(channels)",
            "-c:a", "pcm_s16le",
            out.path
        ])
        return out
    }

    static func run(ffmpeg: String, args: [String]) throws {
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
