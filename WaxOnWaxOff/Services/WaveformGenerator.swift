import Accelerate
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

        var accumulator = VDSPWaveformAccumulator(
            totalFrames: totalFrames,
            channels: Int(format.channelCount),
            targetSamples: targetSamples,
            chunkCapacity: Int(chunkSize)
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

    /// Scalar reference implementation — test-only entry point. The vDSP path
    /// in processAudio is the production engine; parity between the two is
    /// asserted bit-exactly by WaveformVDSPParityTests.
    internal static func generateScalarReference(url: URL, targetSamples: Int = 500) throws -> WaveformData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessingError.analysisError("File does not exist")
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = Int(file.length)

        guard totalFrames > 0 else {
            throw ProcessingError.analysisError("Audio file is empty")
        }

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

/// vDSP-accelerated production engine for waveform bucketing. Bit-exact with
/// the scalar reference (WaveformAccumulator, kept below for parity tests):
/// per-channel bucket peaks use vDSP_maxmgv over bucket-aligned segments (max
/// is order-independent), the mono mixdown is elementwise vDSP with the same
/// channel order and divide as the scalar loop, and the bucket sums keep a
/// sequential float accumulation over the precomputed mono buffer — the same
/// values added in the same order, so the rounding is identical. What this
/// removes is the scalar loop's real cost: a per-frame integer division and
/// per-frame nested-array indexing across every channel.
struct VDSPWaveformAccumulator {
    private let channels: Int
    private let samplesPerBucket: Int
    private let actualBuckets: Int
    private let capacity: Int

    private var bucketSums: [Float]
    private var bucketPeaks: [Float]
    private var bucketCounts: [Int]
    private var channelBucketPeaks: [[Float]]
    private var monoF: [Float]

    private(set) var globalFrame = 0

    init(totalFrames: Int, channels: Int, targetSamples: Int, chunkCapacity: Int) {
        self.channels = channels
        capacity = chunkCapacity
        samplesPerBucket = max(1, totalFrames / targetSamples)
        actualBuckets = (totalFrames + samplesPerBucket - 1) / samplesPerBucket
        bucketSums = [Float](repeating: 0, count: actualBuckets)
        bucketPeaks = [Float](repeating: 0, count: actualBuckets)
        bucketCounts = [Int](repeating: 0, count: actualBuckets)
        channelBucketPeaks = [[Float]](
            repeating: [Float](repeating: 0, count: actualBuckets),
            count: max(channels, 1)
        )
        monoF = [Float](repeating: 0, count: chunkCapacity)
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard let channelData = buffer.floatChannelData else {
            throw ProcessingError.analysisError("Could not access channel data")
        }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        guard n <= capacity else {
            throw ProcessingError.analysisError("Waveform chunk exceeds buffer capacity")
        }
        let count = vDSP_Length(n)

        // Mono mixdown — same channel order and divide as the scalar engine.
        monoF.withUnsafeMutableBufferPointer { m in
            if channels == 1 {
                m.baseAddress!.update(from: channelData[0], count: n)
            } else {
                vDSP_vadd(channelData[0], 1, channelData[1], 1, m.baseAddress!, 1, count)
                for ch in 2..<channels {
                    vDSP_vadd(m.baseAddress!, 1, channelData[ch], 1, m.baseAddress!, 1, count)
                }
            }
            var divisor = Float(channels)
            vDSP_vsdiv(m.baseAddress!, 1, &divisor, m.baseAddress!, 1, count)
        }

        // Bucket-aligned segments. Frames past the last bucket are dropped,
        // matching the scalar loop's overflow guard.
        var offset = 0
        while offset < n {
            let bucketIndex = (globalFrame + offset) / samplesPerBucket
            guard bucketIndex < actualBuckets else { break }
            let bucketEnd = (bucketIndex + 1) * samplesPerBucket
            let seg = min(n - offset, bucketEnd - (globalFrame + offset))
            let segCount = vDSP_Length(seg)

            var frameMax: Float = 0
            for ch in 0..<channels {
                var chMax: Float = 0
                vDSP_maxmgv(channelData[ch] + offset, 1, &chMax, segCount)
                channelBucketPeaks[ch][bucketIndex] = max(channelBucketPeaks[ch][bucketIndex], chMax)
                frameMax = max(frameMax, chMax)
            }
            bucketPeaks[bucketIndex] = max(bucketPeaks[bucketIndex], frameMax)

            monoF.withUnsafeBufferPointer { m in
                let base = m.baseAddress!
                var sum = bucketSums[bucketIndex]
                for i in offset..<(offset + seg) {
                    sum += base[i]
                }
                bucketSums[bucketIndex] = sum
            }
            bucketCounts[bucketIndex] += seg
            offset += seg
        }

        // The scalar loop advances by the full chunk even when the bucket
        // guard dropped trailing frames — preserved for identical indexing.
        globalFrame += n
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

/// Streaming accumulator for waveform bucketing — the scalar reference
/// implementation, kept compiled for the bit-exact parity tests against the
/// vDSP production engine above.
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
