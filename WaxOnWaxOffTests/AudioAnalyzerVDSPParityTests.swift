import XCTest
@testable import WaxOnWaxOff

/// Pins the vDSP production engine to the scalar reference implementation
/// (AudioAnalyzer.analyzeScalarReference). The two engines compute the same
/// measurement definition; any divergence beyond rounding order is a bug.
/// The perf-fix session's full-corpus gate ran at ≤0.01 dB across synthetic
/// and real delivered episodes; this regression test holds a tighter bound
/// on generated material so drift is caught immediately.
final class AudioAnalyzerVDSPParityTests: XCTestCase {

    func testVDSPEngineMatchesScalarReference() async throws {
        let tools = try IntegrationFFmpeg.locate()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vdsp-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var files: [URL] = []
        files.append(try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: dir, name: "sine_stereo_44k.wav",
            durationSeconds: 6.0, sampleRate: 44100, channels: 2))
        files.append(try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: dir, name: "sine_mono_48k.wav",
            durationSeconds: 6.0, sampleRate: 48000, channels: 1))
        // Broadband content exercises the K-weighting cascade and the
        // noise-floor percentile in a way a pure tone cannot.
        let noise = dir.appendingPathComponent("noise_stereo_44k.wav")
        try IntegrationFFmpeg.run(ffmpeg: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i",
            "anoisesrc=color=pink:sample_rate=44100:amplitude=0.3:duration=6:seed=1234",
            "-ac", "2", "-c:a", "pcm_s16le", noise.path
        ])
        files.append(noise)

        for url in files {
            let vdsp = try await AudioAnalyzer.analyze(url: url)
            let scalar = try AudioAnalyzer.analyzeScalarReference(url: url)
            let name = url.lastPathComponent
            XCTAssertEqual(vdsp.rms, scalar.rms, accuracy: 0.001, "rms — \(name)")
            XCTAssertEqual(vdsp.peak, scalar.peak, accuracy: 0.001, "peak — \(name)")
            XCTAssertEqual(vdsp.crest, scalar.crest, accuracy: 0.001, "crest — \(name)")
            XCTAssertEqual(vdsp.lufs, scalar.lufs, accuracy: 0.001, "lufs — \(name)")
            XCTAssertEqual(vdsp.truePeak, scalar.truePeak, accuracy: 0.001, "truePeak — \(name)")
            switch (vdsp.noiseFloor, scalar.noiseFloor) {
            case let (v?, s?):
                XCTAssertEqual(v, s, accuracy: 0.001, "noiseFloor — \(name)")
            case (nil, nil):
                break
            default:
                XCTFail("noiseFloor nil-mismatch — \(name): vdsp=\(String(describing: vdsp.noiseFloor)) scalar=\(String(describing: scalar.noiseFloor))")
            }
        }
    }
}
