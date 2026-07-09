import Foundation
import AVFoundation

struct WaveformData: Sendable, Equatable {
    let samples: [Float]         // Normalized -1 to 1 (mixed down)
    let peaks: [Float]           // Mixed-down peak values per bucket
    let channelPeaks: [[Float]]  // Per-channel peak values; index 0 = L, 1 = R
    let channelCount: Int        // Number of channels in source audio
}

enum WaveformGenerator {
    static func generate(url: URL, targetSamples: Int = 500) async throws -> WaveformData {
        let perfStart = ContinuousClock.now
        let data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try processAudio(url: url, targetSamples: targetSamples)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        PerfLog.record("WaveformGenerator.generate \(url.lastPathComponent)", seconds: PerfLog.seconds(since: perfStart))
        return data
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

        // Read in chunks to avoid loading the entire file into RAM
        let chunkSize: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw ProcessingError.analysisError("Could not create audio buffer")
        }

        var accumulator = WaveformAccumulator(
            totalFrames: totalFrames,
            channels: Int(format.channelCount),
            targetSamples: targetSamples
        )

        file.framePosition = 0

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                if accumulator.globalFrame > 0 { break }
                throw ProcessingError.analysisError("Error reading audio: \(error.localizedDescription)")
            }

            if buffer.frameLength == 0 { break }
            try accumulator.consume(buffer)
        }

        return accumulator.finish()
    }
}

/// Streaming accumulator for waveform bucketing. Extracted verbatim from the
/// previous single-pass implementation so the chunk stream can be shared with
/// the stats analyzer over a single decode — the bucketing math is unchanged.
struct WaveformAccumulator {
    private let channels: Int
    private let samplesPerBucket: Int
    private let actualBuckets: Int

    // Accumulate stats per bucket incrementally. One row per source channel
    // — for mono that's a single row, for stereo two. The mixed-down
    // `peaks` array is always produced; `channelPeaks` lets the stereo
    // waveform view draw L/R lanes when channelCount > 1.
    private var bucketSums: [Float]
    private var bucketPeaks: [Float]
    private var bucketCounts: [Int]
    private var channelBucketPeaks: [[Float]]

    private(set) var globalFrame = 0

    init(totalFrames: Int, channels: Int, targetSamples: Int) {
        self.channels = channels
        samplesPerBucket = max(1, totalFrames / targetSamples)
        actualBuckets = (totalFrames + samplesPerBucket - 1) / samplesPerBucket
        bucketSums = [Float](repeating: 0, count: actualBuckets)
        bucketPeaks = [Float](repeating: 0, count: actualBuckets)
        bucketCounts = [Int](repeating: 0, count: actualBuckets)
        channelBucketPeaks = [[Float]](
            repeating: [Float](repeating: 0, count: actualBuckets),
            count: max(channels, 1)
        )
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
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
                let absSample = abs(sample)
                monoSample += sample
                framePeak = max(framePeak, absSample)
                channelBucketPeaks[channel][bucketIndex] = max(channelBucketPeaks[channel][bucketIndex], absSample)
            }

            monoSample /= Float(channels)
            bucketSums[bucketIndex] += monoSample
            bucketPeaks[bucketIndex] = max(bucketPeaks[bucketIndex], framePeak)
            bucketCounts[bucketIndex] += 1
        }

        globalFrame += frames
    }

    func finish() -> WaveformData {
        var samples: [Float] = []
        var peaks: [Float] = []
        samples.reserveCapacity(actualBuckets)
        peaks.reserveCapacity(actualBuckets)

        for i in 0..<actualBuckets {
            let avg = bucketCounts[i] > 0 ? bucketSums[i] / Float(bucketCounts[i]) : 0
            samples.append(avg)
            peaks.append(bucketPeaks[i])
        }

        return WaveformData(samples: samples, peaks: peaks, channelPeaks: channelBucketPeaks, channelCount: channels)
    }
}
