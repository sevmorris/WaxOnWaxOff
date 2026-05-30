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
            let formatLabel = codecLabel(for: fmt, fallback: ext.isEmpty ? "Audio" : ext)

            var bitRate: Double? = nil
            if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64),
               dur > 0 {
                bitRate = Double(sz * 8) / dur
            }

            return FileInfo(
                format: formatLabel,
                sampleRate: sr,
                channelCount: Int(fmt.channelCount),
                bitDepth: bitDepth,
                duration: dur,
                bitRate: bitRate
            )
        }
    }

    /// Map AVFoundation's format ID to a short, user-facing codec name. For PCM
    /// (which lives natively in WAV/AIFF/CAF) the container extension is more
    /// informative than the literal "PCM", so we fall back to it. For lossy or
    /// lossless-compressed audio inside a video container (MP4/MOV) we want
    /// the codec name (AAC, ALAC, …) rather than the container name.
    private static func codecLabel(for fmt: AVAudioFormat, fallback: String) -> String {
        guard let formatID = fmt.settings[AVFormatIDKey] as? UInt32 else { return fallback }

        switch formatID {
        case kAudioFormatLinearPCM:
            return fallback
        case kAudioFormatMPEGLayer3:
            return "MP3"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD,
             kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_Spatial:
            return "AAC"
        case kAudioFormatFLAC:
            return "FLAC"
        case kAudioFormatOpus:
            return "Opus"
        case kAudioFormatAppleLossless:
            return "ALAC"
        case kAudioFormatAC3:
            return "AC3"
        case kAudioFormatEnhancedAC3:
            return "EAC3"
        default:
            return fallback
        }
    }

    /// - Parameter noiseFloorHighPassHz: HPF for noise-floor blocks — use 80 when WaxOn HPF is on, 20 when off.
    static func analyze(url: URL, noiseFloorHighPassHz: Double = 80) async throws -> AudioStats {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let stats = try performAnalysis(url: url, noiseFloorHighPassHz: noiseFloorHighPassHz)
                    continuation.resume(returning: stats)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performAnalysis(url: URL, noiseFloorHighPassHz: Double) throws -> AudioStats {
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

            // Butterworth HPF for the noise-floor mono path. Matches WaxOn's HPF stage
            // (80 Hz on, 20 Hz DC floor when off). Doesn't touch peak, RMS, or LUFS.
            let nfHp = NoiseFloorHPF(sampleRate: sr, cutoffHz: noiseFloorHighPassHz)
            var nfHpW1: Double = 0
            var nfHpW2: Double = 0

            // Per-channel K-weighting biquad state (transposed direct form II)
            var preW1 = [Double](repeating: 0, count: channels)
            var preW2 = [Double](repeating: 0, count: channels)
            var hpW1  = [Double](repeating: 0, count: channels)
            var hpW2  = [Double](repeating: 0, count: channels)

            // LUFS: 400 ms blocks at 75% overlap (one new block every 100 ms).
            // Implemented as a 4-deep ring of 100 ms hop sums; each completed
            // ring emits a block. Matches ITU-R BS.1770 / EBU R128.
            //
            // Each block's "loudness energy" is Σ G_ch · z_ch (channel-weighted
            // sum of per-channel mean-squares). For the mono/stereo/LCR sources
            // this app processes the channel weights are all 1.0; surround
            // weights (1.41 for Ls/Rs) aren't applied because AVAudioFile
            // doesn't reliably expose channel layout for arbitrary inputs.
            let hopFrames = max(1, Int((sr * 0.1).rounded()))
            let hopsPerBlock = 4
            var hopChannelSumSq = [Double](repeating: 0, count: channels)
            var hopFramesElapsed = 0
            var hopHistorySS: [[Double]] = Array(repeating: [], count: channels)
            var hopHistoryFrames: [Int] = []
            var blockLoudnessEnergies = [Double]()

            // Noise floor: non-overlapping 400 ms blocks of HP-filtered mono RMS.
            let nfBlockFrames = max(1, Int((sr * 0.4).rounded()))
            var nfBlockMonoSumSq: Double = 0
            var nfBlockFramesElapsed = 0
            var blockRmsValues = [Double]()

            file.framePosition = 0
            var sumSquares: Double = 0
            var peak: Double = 0
            var truePeak: Double = 0
            var lastSample = [Double](repeating: 0, count: channels)
            var hasLastSample = [Bool](repeating: false, count: channels)
            var totalFrames: Int = 0

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
                        let absX = abs(x)
                        peak = max(peak, absX)
                        if hasLastSample[ch] {
                            let mid = abs((lastSample[ch] + x) / 2.0)
                            truePeak = max(truePeak, mid)
                        }
                        truePeak = max(truePeak, absX)
                        lastSample[ch] = x
                        hasLastSample[ch] = true

                        // Stage 1: pre-filter (biquad, transposed direct form II)
                        let y1 = kw.pre_b0 * x + preW1[ch]
                        preW1[ch] = kw.pre_b1 * x - kw.pre_a1 * y1 + preW2[ch]
                        preW2[ch] = kw.pre_b2 * x - kw.pre_a2 * y1

                        // Stage 2: HP weighting filter
                        let y2 = kw.hp_b0 * y1 + hpW1[ch]
                        hpW1[ch] = kw.hp_b1 * y1 - kw.hp_a1 * y2 + hpW2[ch]
                        hpW2[ch] = kw.hp_b2 * y1 - kw.hp_a2 * y2

                        hopChannelSumSq[ch] += y2 * y2
                        monoSample += Float(x)
                    }

                    monoSample /= Float(channels)
                    let doubleMono = Double(monoSample)
                    sumSquares += doubleMono * doubleMono

                    // HPF on mono path before noise-floor accumulation
                    let nfFiltered = nfHp.process(doubleMono, w1: &nfHpW1, w2: &nfHpW2)
                    nfBlockMonoSumSq += nfFiltered * nfFiltered

                    hopFramesElapsed += 1
                    nfBlockFramesElapsed += 1

                    // 100 ms hop boundary: push hop into ring, possibly emit a block.
                    if hopFramesElapsed >= hopFrames {
                        for ch in 0..<channels {
                            hopHistorySS[ch].append(hopChannelSumSq[ch])
                            if hopHistorySS[ch].count > hopsPerBlock { hopHistorySS[ch].removeFirst() }
                            hopChannelSumSq[ch] = 0
                        }
                        hopHistoryFrames.append(hopFramesElapsed)
                        if hopHistoryFrames.count > hopsPerBlock { hopHistoryFrames.removeFirst() }
                        hopFramesElapsed = 0

                        if hopHistoryFrames.count == hopsPerBlock {
                            let totalHopFrames = hopHistoryFrames.reduce(0, +)
                            // BS.1770: block loudness = Σ G_ch · z_ch. Channel
                            // weights G are 1.0 for L/R/C; we don't have
                            // layout info to apply 1.41 to Ls/Rs, so we sum
                            // unweighted (correct for mono/stereo, slightly
                            // low for true surround).
                            var blockSumSq = 0.0
                            for ch in 0..<channels {
                                let sumSS = hopHistorySS[ch].reduce(0, +)
                                blockSumSq += sumSS / Double(totalHopFrames)
                            }
                            blockLoudnessEnergies.append(blockSumSq)
                        }
                    }

                    // 400 ms noise-floor block boundary
                    if nfBlockFramesElapsed >= nfBlockFrames {
                        let nfRms = sqrt(nfBlockMonoSumSq / Double(nfBlockFramesElapsed))
                        blockRmsValues.append(nfRms)
                        nfBlockMonoSumSq = 0
                        nfBlockFramesElapsed = 0
                    }
                }
                totalFrames += frames
            }

            // Flush partial trailing data so very short clips still produce a
            // measurement. For LUFS, only emit a partial block if no full block
            // was ever completed — otherwise we'd skew the gated mean.
            if blockLoudnessEnergies.isEmpty {
                let trailingFrames = hopHistoryFrames.reduce(0, +) + hopFramesElapsed
                if trailingFrames > 0 {
                    var blockSumSq = 0.0
                    for ch in 0..<channels {
                        let sumSS = hopHistorySS[ch].reduce(0, +) + hopChannelSumSq[ch]
                        blockSumSq += sumSS / Double(trailingFrames)
                    }
                    blockLoudnessEnergies.append(blockSumSq)
                }
            }
            if nfBlockFramesElapsed > 0 {
                let nfRms = sqrt(nfBlockMonoSumSq / Double(nfBlockFramesElapsed))
                blockRmsValues.append(nfRms)
            }

            guard totalFrames > 0 else {
                throw ProcessingError.analysisError("No frames to process")
            }

            let rms = sqrt(sumSquares / Double(totalFrames))
            let rmsDb = 20 * log10(max(rms, 1e-12))
            let peakDb = 20 * log10(max(peak, 1e-12))
            let truePeakDb = 20 * log10(max(truePeak, 1e-12))
            let crestDb = peakDb - rmsDb
            let lufs = computeGatedLUFS(blockEnergies: blockLoudnessEnergies)

            // Noise floor: 10th percentile of per-block RMS (quietest blocks ≈ room tone / noise).
            // Uses linear-interpolation (Type 7) percentile so the result lines up with the
            // common Excel/R/NumPy convention. The previous `Int(count * 0.1)` formula was
            // biased one rank high on long files and degenerate (returned MIN) for counts
            // around 5–10 where the bucket edge fell on index 0.
            let noiseFloor: Double?
            if blockRmsValues.count >= 5 {
                let sorted = blockRmsValues.sorted()
                let rank = Double(sorted.count - 1) * 0.1
                let lo = Int(rank.rounded(.down))
                let hi = min(sorted.count - 1, lo + 1)
                let frac = rank - Double(lo)
                let p10Rms = sorted[lo] * (1 - frac) + sorted[hi] * frac
                noiseFloor = 20 * log10(max(p10Rms, 1e-12))
            } else {
                noiseFloor = nil
            }

            return AudioStats(
                rms: rmsDb,
                peak: peakDb,
                crest: crestDb,
                lufs: lufs,
                noiseFloor: noiseFloor,
                truePeak: truePeakDb
            )
        }
    }

    /// Applies ITU-R BS.1770 absolute + relative gating to per-block loudness
    /// energies (Σ G_ch · z_ch values, one per 400 ms / 75%-overlap block).
    private static func computeGatedLUFS(blockEnergies: [Double]) -> Double {
        guard !blockEnergies.isEmpty else { return -144.0 }

        // Absolute gate: -70 LUFS → energy threshold = 10^((-70+0.691)/10)
        let absThreshold = pow(10.0, (-70.0 + 0.691) / 10.0)
        let absoluteGated = blockEnergies.filter { $0 > absThreshold }
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

/// 2nd-order Butterworth high-pass biquad. Used by the analyzer to match WaxOn's
/// HPF stage when estimating the noise floor.
private struct NoiseFloorHPF {
    let b0, b1, b2, a1, a2: Double

    init(sampleRate: Double, cutoffHz: Double) {
        let f0 = max(20.0, cutoffHz)
        let K = tan(.pi * f0 / sampleRate)
        let Ksq = K * K
        let Q = 1.0 / 2.0.squareRoot()  // Butterworth
        let d = 1 + K / Q + Ksq
        b0 = 1.0 / d
        b1 = -2.0 / d
        b2 = 1.0 / d
        a1 = 2 * (Ksq - 1) / d
        a2 = (1 - K / Q + Ksq) / d
    }

    func process(_ x: Double, w1: inout Double, w2: inout Double) -> Double {
        let y = b0 * x + w1
        w1 = b1 * x - a1 * y + w2
        w2 = b2 * x - a2 * y
        return y
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
