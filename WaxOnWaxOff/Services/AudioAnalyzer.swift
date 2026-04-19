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

    static func analyze(url: URL) async throws -> AudioStats {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let stats = try performAnalysis(url: url)
                    continuation.resume(returning: stats)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performAnalysis(url: URL) throws -> AudioStats {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessingError.analysisError("File does not exist")
        }

        // autoreleasepool ensures the file descriptor is returned to the OS promptly,
        // preventing fd exhaustion when many files are analyzed concurrently.
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

        // ITU-R BS.1770 K-weighting filter coefficients for this sample rate
        let kw = KWeightCoeffs(sampleRate: sr)

        // Per-channel biquad state (transposed direct form II)
        var preW1 = [Double](repeating: 0, count: channels)
        var preW2 = [Double](repeating: 0, count: channels)
        var hpW1  = [Double](repeating: 0, count: channels)
        var hpW2  = [Double](repeating: 0, count: channels)

        // LUFS: non-overlapping 400 ms blocks
        let blockFrames = max(1, Int(sr * 0.4))
        var blockChannelSumSq = [Double](repeating: 0, count: channels)
        var blockCurrentFrames = 0
        var blockMeanSqs = [Double]()
        var blockRmsValues = [Double]()  // per-block RMS for noise floor estimation

        file.framePosition = 0
        var sumSquares: Double = 0
        var peak: Double = 0
        var totalFrames: Int = 0
        var blockMonoSumSq: Double = 0  // mono sum-of-squares for current block

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
                var monoSample: Float = 0
                for ch in 0..<channels {
                    let x = Double(channelData[ch][frame])
                    peak = max(peak, abs(x))

                    // Stage 1: pre-filter (biquad, transposed direct form II)
                    let y1 = kw.pre_b0 * x + preW1[ch]
                    preW1[ch] = kw.pre_b1 * x - kw.pre_a1 * y1 + preW2[ch]
                    preW2[ch] = kw.pre_b2 * x - kw.pre_a2 * y1

                    // Stage 2: HP weighting filter
                    let y2 = kw.hp_b0 * y1 + hpW1[ch]
                    hpW1[ch] = kw.hp_b1 * y1 - kw.hp_a1 * y2 + hpW2[ch]
                    hpW2[ch] = kw.hp_b2 * y1 - kw.hp_a2 * y2

                    blockChannelSumSq[ch] += y2 * y2
                    monoSample += Float(x)
                }

                monoSample /= Float(channels)
                let doubleMono = Double(monoSample)
                sumSquares += doubleMono * doubleMono
                blockMonoSumSq += doubleMono * doubleMono

                // Complete a block when it reaches 400 ms
                blockCurrentFrames += 1
                if blockCurrentFrames >= blockFrames {
                    var avgSq = 0.0
                    for ch in 0..<channels { avgSq += blockChannelSumSq[ch] / Double(blockCurrentFrames) }
                    avgSq /= Double(channels)
                    blockMeanSqs.append(avgSq)

                    // Track per-block mono RMS for noise floor estimation
                    let blockRms = sqrt(blockMonoSumSq / Double(blockCurrentFrames))
                    blockRmsValues.append(blockRms)

                    blockChannelSumSq = [Double](repeating: 0, count: channels)
                    blockMonoSumSq = 0
                    blockCurrentFrames = 0
                }
            }
            totalFrames += frames
        }

        // Flush partial last block (if any)
        if blockCurrentFrames > 0 {
            var avgSq = 0.0
            for ch in 0..<channels { avgSq += blockChannelSumSq[ch] / Double(blockCurrentFrames) }
            avgSq /= Double(channels)
            blockMeanSqs.append(avgSq)

            let blockRms = sqrt(blockMonoSumSq / Double(blockCurrentFrames))
            blockRmsValues.append(blockRms)
        }

        guard totalFrames > 0 else {
            throw ProcessingError.analysisError("No frames to process")
        }

        let rms = sqrt(sumSquares / Double(totalFrames))
        let rmsDb = 20 * log10(max(rms, 1e-12))
        let peakDb = 20 * log10(max(peak, 1e-12))
        let crestDb = peakDb - rmsDb
        let lufs = computeGatedLUFS(blockMeanSqs: blockMeanSqs)

        // Noise floor: 10th percentile of per-block RMS (quietest blocks ≈ room tone / noise)
        let noiseFloor: Double?
        if blockRmsValues.count >= 5 {
            let sorted = blockRmsValues.sorted()
            let p10Index = max(0, Int(Double(sorted.count) * 0.1))
            let p10Rms = sorted[p10Index]
            noiseFloor = 20 * log10(max(p10Rms, 1e-12))
        } else {
            noiseFloor = nil
        }

        return AudioStats(rms: rmsDb, peak: peakDb, crest: crestDb, lufs: lufs, noiseFloor: noiseFloor)
        } // end autoreleasepool
    }

    /// Applies ITU-R BS.1770 absolute + relative gating to block mean-squares.
    private static func computeGatedLUFS(blockMeanSqs: [Double]) -> Double {
        guard !blockMeanSqs.isEmpty else { return -144.0 }

        // Absolute gate: -70 LUFS → meanSq threshold = 10^((-70+0.691)/10)
        let absThreshold = pow(10.0, (-70.0 + 0.691) / 10.0)
        let absoluteGated = blockMeanSqs.filter { $0 > absThreshold }
        guard !absoluteGated.isEmpty else { return -70.0 }

        let ungatedMean = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let ungatedLUFS = -0.691 + 10 * log10(max(ungatedMean, 1e-10))

        // Relative gate: 10 LU below ungated integrated
        let relThreshold = pow(10.0, (ungatedLUFS - 10.0 + 0.691) / 10.0)
        let relativeGated = absoluteGated.filter { $0 > relThreshold }
        guard !relativeGated.isEmpty else { return ungatedLUFS }

        let gatedMean = relativeGated.reduce(0, +) / Double(relativeGated.count)
        return -0.691 + 10 * log10(max(gatedMean, 1e-10))
    }
}

/// ITU-R BS.1770 K-weighting biquad filter coefficients, computed for any sample rate.
/// Based on the pyloudnorm reference implementation.
private struct KWeightCoeffs {
    // Stage 1: pre-filter (psychoacoustic high-shelf)
    let pre_b0, pre_b1, pre_b2, pre_a1, pre_a2: Double
    // Stage 2: RLB high-pass weighting filter
    let hp_b0, hp_b1, hp_b2, hp_a1, hp_a2: Double

    init(sampleRate: Double) {
        let sqrt2 = 2.0.squareRoot()

        // Stage 1
        let db: Double = 3.999843853973347
        let f0: Double = 1681.974450955533
        let Ks = tan(Double.pi * f0 / sampleRate)
        let Kssq = Ks * Ks
        let Vh = pow(10.0, db / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let d1 = 1 + sqrt2 * Ks + Kssq
        pre_b0 = (Vh + Vb * sqrt2 * Ks + Kssq) / d1
        pre_b1 = 2 * (Kssq - Vh) / d1
        pre_b2 = (Vh - Vb * sqrt2 * Ks + Kssq) / d1
        pre_a1 = 2 * (Kssq - 1) / d1
        pre_a2 = (1 - sqrt2 * Ks + Kssq) / d1

        // Stage 2
        let f0h: Double = 38.13547087602444
        let Q:   Double = 0.5003270373253953
        let Kh   = tan(Double.pi * f0h / sampleRate)
        let Khsq = Kh * Kh
        let d2 = 1 + Kh / Q + Khsq
        hp_b0 =  1.0 / d2
        hp_b1 = -2.0 / d2
        hp_b2 =  1.0 / d2
        hp_a1 = 2 * (Khsq - 1) / d2
        hp_a2 = (1 - Kh / Q + Khsq) / d2
    }
}
