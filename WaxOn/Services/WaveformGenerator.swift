import Foundation
import AVFoundation

struct WaveformData: Sendable, Equatable {
    let samples: [Float]  // Normalized -1 to 1
    let peaks: [Float]    // Peak values for each sample point
    let channelCount: Int // Number of channels in source audio
}

enum WaveformGenerator {
    static func generate(url: URL, targetSamples: Int = 500) async throws -> WaveformData {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try processAudio(url: url, targetSamples: targetSamples)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func processAudio(url: URL, targetSamples: Int) throws -> WaveformData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessingError.analysisError("File does not exist")
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = Int(file.length)

        guard totalFrames > 0 else {
            throw ProcessingError.analysisError("Audio file is empty")
        }

        let channels = Int(format.channelCount)
        let samplesPerBucket = max(1, totalFrames / targetSamples)
        let actualBuckets = (totalFrames + samplesPerBucket - 1) / samplesPerBucket

        // Accumulate stats per bucket incrementally
        var bucketSums = [Float](repeating: 0, count: actualBuckets)
        var bucketPeaks = [Float](repeating: 0, count: actualBuckets)
        var bucketCounts = [Int](repeating: 0, count: actualBuckets)

        // Read in chunks to avoid loading the entire file into RAM
        let chunkSize: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw ProcessingError.analysisError("Could not create audio buffer")
        }

        file.framePosition = 0
        var globalFrame = 0

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                if globalFrame > 0 { break }
                throw ProcessingError.analysisError("Error reading audio: \(error.localizedDescription)")
            }

            if buffer.frameLength == 0 { break }

            guard let channelData = buffer.floatChannelData else {
                throw ProcessingError.analysisError("Could not access channel data")
            }

            let frames = Int(buffer.frameLength)
            for frame in 0..<frames {
                let bucketIndex = (globalFrame + frame) / samplesPerBucket
                guard bucketIndex < actualBuckets else { break }

                var monoSample: Float = 0
                var framePeak: Float = 0

                for channel in 0..<channels {
                    let sample = channelData[channel][frame]
                    monoSample += sample
                    framePeak = max(framePeak, abs(sample))
                }

                monoSample /= Float(channels)
                bucketSums[bucketIndex] += monoSample
                bucketPeaks[bucketIndex] = max(bucketPeaks[bucketIndex], framePeak)
                bucketCounts[bucketIndex] += 1
            }

            globalFrame += frames
        }

        var samples: [Float] = []
        var peaks: [Float] = []
        samples.reserveCapacity(actualBuckets)
        peaks.reserveCapacity(actualBuckets)

        for i in 0..<actualBuckets {
            let avg = bucketCounts[i] > 0 ? bucketSums[i] / Float(bucketCounts[i]) : 0
            samples.append(avg)
            peaks.append(bucketPeaks[i])
        }

        return WaveformData(samples: samples, peaks: peaks, channelCount: channels)
    }
}
