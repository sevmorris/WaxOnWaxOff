import Foundation
import AVFoundation

enum AudioAnalyzer {
    static func info(url: URL) async throws -> FileInfo {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let info = try gatherInfo(url: url)
                    continuation.resume(returning: info)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func gatherInfo(url: URL) throws -> FileInfo {
        try autoreleasepool {
            let file = try AVAudioFile(forReading: url)
            let fmt = file.fileFormat
            let sr = fmt.sampleRate
            let dur = sr > 0 ? Double(file.length) / sr : 0
            let bitDepth = fmt.settings[AVLinearPCMBitDepthKey] as? Int
            let ext = url.pathExtension.uppercased()

            var bitRate: Double? = nil
            if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64),
               dur > 0 {
                bitRate = Double(sz * 8) / dur
            }

            return FileInfo(
                format: ext.isEmpty ? "Audio" : ext,
                sampleRate: sr,
                channelCount: Int(fmt.channelCount),
                bitDepth: bitDepth,
                duration: dur,
                bitRate: bitRate
            )
        }
    }

    /// Analyze audio stats. LUFS is measured via FFmpeg loudnorm (same algorithm as the
    /// processing pipeline); peak/RMS/crest/noise are measured via AVFoundation in parallel.
    static func analyze(url: URL) async throws -> AudioStats {
        let ffmpeg = try await FFmpegManager.shared.ensureTools().ffmpeg
        async let sample = computeSampleStats(url: url)
        async let lufs = measureLUFS(url: url, ffmpeg: ffmpeg)
        let (s, l) = try await (sample, lufs)
        return AudioStats(rms: s.rms, peak: s.peak, crest: s.crest, lufs: l, noiseFloor: s.noiseFloor)
    }

    // MARK: - Private

    private struct SampleStats {
        let rms: Double
        let peak: Double
        let crest: Double
        let noiseFloor: Double?
    }

    private static func computeSampleStats(url: URL) async throws -> SampleStats {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let stats = try gatherSampleStats(url: url)
                    continuation.resume(returning: stats)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func gatherSampleStats(url: URL) throws -> SampleStats {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessingError.analysisError("File does not exist")
        }

        return try autoreleasepool {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw ProcessingError.analysisError("Could not open audio file: \(error.localizedDescription)")
            }

            let format = file.processingFormat
            let frameCount = Int64(file.length)

            guard frameCount > 0 else {
                throw ProcessingError.analysisError("Audio file is empty")
            }

            let chunkSize: AVAudioFrameCount = 32768
            let channels = Int(format.channelCount)
            let sr = format.sampleRate

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
                throw ProcessingError.analysisError("Could not create audio buffer")
            }

            let blockFrames = max(1, Int(sr * 0.4))
            var blockMonoSumSq = 0.0
            var blockCurrentFrames = 0
            var blockRmsValues: [Double] = []

            var sumSquares = 0.0
            var peak = 0.0
            var totalFrames = 0

            file.framePosition = 0

            while file.framePosition < frameCount {
                do {
                    try file.read(into: buffer)
                } catch {
                    if totalFrames > 0 { break }
                    throw ProcessingError.analysisError("Error reading audio: \(error.localizedDescription)")
                }

                if buffer.frameLength == 0 { break }

                guard let channelData = buffer.floatChannelData else {
                    throw ProcessingError.analysisError("Could not access channel data")
                }

                let frames = Int(buffer.frameLength)
                for frame in 0..<frames {
                    var monoSample = 0.0
                    for ch in 0..<channels {
                        let x = Double(channelData[ch][frame])
                        peak = max(peak, abs(x))
                        monoSample += x
                    }
                    monoSample /= Double(channels)
                    sumSquares += monoSample * monoSample
                    blockMonoSumSq += monoSample * monoSample

                    blockCurrentFrames += 1
                    if blockCurrentFrames >= blockFrames {
                        blockRmsValues.append(sqrt(blockMonoSumSq / Double(blockCurrentFrames)))
                        blockMonoSumSq = 0
                        blockCurrentFrames = 0
                    }
                }
                totalFrames += frames
            }

            if blockCurrentFrames > 0 {
                blockRmsValues.append(sqrt(blockMonoSumSq / Double(blockCurrentFrames)))
            }

            guard totalFrames > 0 else {
                throw ProcessingError.analysisError("No frames to process")
            }

            let rms = sqrt(sumSquares / Double(totalFrames))
            let rmsDb = 20 * log10(max(rms, 1e-12))
            let peakDb = 20 * log10(max(peak, 1e-12))
            let crestDb = peakDb - rmsDb

            let noiseFloor: Double?
            if blockRmsValues.count >= 5 {
                let sorted = blockRmsValues.sorted()
                let p10Index = max(0, Int(Double(sorted.count) * 0.1))
                noiseFloor = 20 * log10(max(sorted[p10Index], 1e-12))
            } else {
                noiseFloor = nil
            }

            return SampleStats(rms: rmsDb, peak: peakDb, crest: crestDb, noiseFloor: noiseFloor)
        }
    }

    private static func measureLUFS(url: URL, ffmpeg: String) async throws -> Double {
        let output = try await FFmpegRunner.capture(
            exe: ffmpeg,
            args: [
                "-hide_banner", "-nostats",
                "-i", url.path,
                "-af", "loudnorm=I=-16:TP=-1:LRA=11:print_format=json",
                "-f", "null", "/dev/null"
            ]
        )
        guard let dict = FFmpegRunner.parseLoudnormJSON(from: output),
              let inputI = dict["input_i"],
              let lufs = Double(inputI) else {
            throw ProcessingError.analysisError("Could not parse LUFS from FFmpeg output")
        }
        return lufs
    }
}
