import XCTest
@testable import WaxOnWaxOff

/// Pins the vDSP waveform engine to the scalar reference implementation
/// (WaveformGenerator.generateScalarReference) with BIT-EXACT equality: the
/// vectorized engine preserves the scalar accumulation order for bucket sums
/// and uses order-independent maxes for peaks, so every output float must be
/// identical. Any inequality is a bug, not tolerance drift.
final class WaveformVDSPParityTests: XCTestCase {

    func testVDSPEngineIsBitExactWithScalarReference() async throws {
        let tools = try IntegrationFFmpeg.locate()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var files: [URL] = []
        files.append(try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: dir, name: "sine_stereo_44k.wav",
            durationSeconds: 6.0, sampleRate: 44100, channels: 2))
        files.append(try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: dir, name: "sine_mono_48k.wav",
            durationSeconds: 6.0, sampleRate: 48000, channels: 1))
        let noise = dir.appendingPathComponent("noise_stereo_44k.wav")
        try IntegrationFFmpeg.run(ffmpeg: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i",
            "anoisesrc=color=pink:sample_rate=44100:amplitude=0.3:duration=6:seed=4321",
            "-ac", "2", "-c:a", "pcm_s16le", noise.path
        ])
        files.append(noise)

        for url in files {
            let vdsp = try await WaveformGenerator.generate(url: url)
            let scalar = try WaveformGenerator.generateScalarReference(url: url)
            let name = url.lastPathComponent
            XCTAssertEqual(vdsp.samples, scalar.samples, "samples not bit-exact — \(name)")
            XCTAssertEqual(vdsp.peaks, scalar.peaks, "peaks not bit-exact — \(name)")
            XCTAssertEqual(vdsp.channelPeaks, scalar.channelPeaks, "channelPeaks not bit-exact — \(name)")
            XCTAssertEqual(vdsp.channelCount, scalar.channelCount, "channelCount — \(name)")
        }
    }
}
