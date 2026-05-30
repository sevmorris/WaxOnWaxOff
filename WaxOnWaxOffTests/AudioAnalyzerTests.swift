import XCTest
import AVFoundation
@testable import WaxOnWaxOff

/// Native-analyzer (no FFmpeg) tests. AVAudioFile handles WAV write/read, so
/// these run anywhere — no integration-time skip needed.
final class AudioAnalyzerTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxon-analyzer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// BS.1770 says block loudness is Σ G_ch · z_ch (channel-weighted sum, not
    /// average). For dual-mono stereo where L = R, the integrated LUFS must be
    /// exactly 10·log10(2) ≈ 3.01 dB louder than the mono equivalent. The prior
    /// implementation divided by channel count and produced the same LUFS for
    /// both, ~3 dB low on every stereo file.
    func testStereoDualMonoLUFSExceedsMonoBy3dB() async throws {
        let monoURL = workDir.appendingPathComponent("mono.wav")
        let stereoURL = workDir.appendingPathComponent("stereo.wav")
        try writeSineWAV(at: monoURL, channels: 1, durationSeconds: 3.0, amplitude: 0.25)
        try writeSineWAV(at: stereoURL, channels: 2, durationSeconds: 3.0, amplitude: 0.25)

        let monoStats = try await AudioAnalyzer.analyze(url: monoURL)
        let stereoStats = try await AudioAnalyzer.analyze(url: stereoURL)

        let delta = stereoStats.lufs - monoStats.lufs
        XCTAssertEqual(delta, 10.0 * log10(2.0), accuracy: 0.15,
                       "Dual-mono stereo must read ~3.01 dB louder than mono per BS.1770 channel summation")
    }

    /// Mono and stereo (dual-mono) RMS in dBFS are equal — RMS is a per-sample
    /// energy measure independent of channel layout. Guards against accidentally
    /// "fixing" the RMS path the same way the LUFS fix moved the channel-sum
    /// math.
    func testStereoDualMonoRMSMatchesMono() async throws {
        let monoURL = workDir.appendingPathComponent("mono_rms.wav")
        let stereoURL = workDir.appendingPathComponent("stereo_rms.wav")
        try writeSineWAV(at: monoURL, channels: 1, durationSeconds: 2.0, amplitude: 0.5)
        try writeSineWAV(at: stereoURL, channels: 2, durationSeconds: 2.0, amplitude: 0.5)

        let monoStats = try await AudioAnalyzer.analyze(url: monoURL)
        let stereoStats = try await AudioAnalyzer.analyze(url: stereoURL)

        XCTAssertEqual(stereoStats.rms, monoStats.rms, accuracy: 0.05)
        XCTAssertEqual(stereoStats.peak, monoStats.peak, accuracy: 0.05)
    }

    /// MP4/MOV inputs used to display FORMAT = container ext (e.g. "MP4"),
    /// hiding the audio codec. AVFormatIDKey lookup now reports the codec.
    /// For PCM-native containers (WAV/AIFF/CAF) we still show the container
    /// extension, since "PCM" is less informative than "WAV".
    func testInfoFormatLabelForPCMWAV() async throws {
        let url = workDir.appendingPathComponent("pcm.wav")
        try writeSineWAV(at: url, channels: 1, durationSeconds: 0.5, amplitude: 0.1)
        let info = try await AudioAnalyzer.info(url: url)
        XCTAssertEqual(info.format, "WAV")
    }

    // MARK: -

    /// Generates a 1 kHz sine at the given amplitude, at 48 kHz Float32, and
    /// writes it as a WAV. AVAudioFile chooses the underlying file format from
    /// the URL extension.
    private func writeSineWAV(
        at url: URL,
        channels: AVAudioChannelCount,
        durationSeconds: Double,
        amplitude: Float,
        frequency: Double = 1000
    ) throws {
        let sampleRate: Double = 48000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioAnalyzerTests", code: 1)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioAnalyzerTests", code: 2)
        }
        buffer.frameLength = frameCount

        let omega = 2.0 * Double.pi * frequency / sampleRate
        let channelData = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(Double(frame) * omega)) * amplitude
            for ch in 0..<Int(channels) {
                channelData[ch][frame] = sample
            }
        }

        try file.write(from: buffer)
    }
}
