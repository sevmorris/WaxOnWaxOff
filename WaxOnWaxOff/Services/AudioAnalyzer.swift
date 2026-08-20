import Accelerate
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

    /// Combined single-decode pass: full stats analysis plus waveform bucketing
    /// from one stream of the file. The post-render refresh previously decoded
    /// the rendered WAV twice — once per consumer; this feeds both accumulators
    /// from the same chunk stream. The math of each consumer is unchanged.
    static func analyzeWithWaveform(
        url: URL,
        noiseFloorHighPassHz: Double = 80,
        targetSamples: Int = 500
    ) async throws -> (stats: AudioStats, waveform: WaveformData) {
        let result: (AudioStats, WaveformData) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try performCombinedAnalysis(
                        url: url,
                        noiseFloorHighPassHz: noiseFloorHighPassHz,
                        targetSamples: targetSamples
                    )
                    continuation.resume(returning: r)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return result
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
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
                throw ProcessingError.analysisError("Could not create audio buffer")
            }

            var analysis = VDSPAnalysisAccumulator(format: format, noiseFloorHighPassHz: noiseFloorHighPassHz, chunkCapacity: Int(chunkSize))

            file.framePosition = 0
            while file.framePosition < frameCount {
                do {
                    try file.read(into: buffer)
                } catch {
                    if analysis.totalFrames > 0 { break }
                    throw ProcessingError.analysisError("Error reading audio: \(error.localizedDescription)")
                }

                if buffer.frameLength == 0 { break }
                try analysis.consume(buffer)
            }

            return try analysis.finish()
        }
    }

    private static func performCombinedAnalysis(
        url: URL,
        noiseFloorHighPassHz: Double,
        targetSamples: Int
    ) throws -> (AudioStats, WaveformData) {
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
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
                throw ProcessingError.analysisError("Could not create audio buffer")
            }

            var analysis = VDSPAnalysisAccumulator(format: format, noiseFloorHighPassHz: noiseFloorHighPassHz, chunkCapacity: Int(chunkSize))
            var waveform = VDSPWaveformAccumulator(
                totalFrames: Int(frameCount),
                channels: Int(format.channelCount),
                targetSamples: targetSamples,
                chunkCapacity: Int(chunkSize)
            )

            file.framePosition = 0
            while file.framePosition < frameCount {
                do {
                    try file.read(into: buffer)
                } catch {
                    if analysis.totalFrames > 0 { break }
                    throw ProcessingError.analysisError("Error reading audio: \(error.localizedDescription)")
                }

                if buffer.frameLength == 0 { break }
                try analysis.consume(buffer)
                try waveform.consume(buffer)
            }

            return (try analysis.finish(), waveform.finish())
        }
    }

    /// Applies ITU-R BS.1770 absolute + relative gating to per-block loudness
    /// energies (Σ G_ch · z_ch values, one per 400 ms / 75%-overlap block).
    /// fileprivate: also called from VDSPAnalysisAccumulator.finish() below.
    fileprivate static func computeGatedLUFS(blockEnergies: [Double]) -> Double {
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

/// vDSP-accelerated engine for the stats analysis: BS.1770 K-weighting via two
/// cascaded biquads, 400 ms / 75%-overlap gating blocks, sample +
/// 2×-interpolated peak, mono RMS, and HP-filtered noise-floor blocks. Filters
/// run through vDSP_deq22D with an explicit two-sample history carried across
/// chunks (zero-initialized); energy sums use vDSP_svesqD per hop/block segment
/// so gating boundaries land on exact frame counts.
private struct VDSPAnalysisAccumulator {
    private let channels: Int
    private let sr: Double
    private let capacity: Int

    // Coefficients in vDSP_deq22D layout: [b0, b1, b2, a1, a2] with
    // y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2].
    private let stage1Coeffs: [Double]
    private let stage2Coeffs: [Double]
    private let nfCoeffs: [Double]

    // Filter I/O buffers with two history slots at the front — deq22D reads
    // A[0..1] / D[0..1] as x[−2..−1] / y[−2..−1] and writes D[2 ..< 2+n].
    private var xBuf: [[Double]]
    private var y1Buf: [[Double]]
    private var y2Buf: [[Double]]
    private var monoF: [Float]
    private var monoD: [Double]
    private var nfBuf: [Double]
    private var mids: [Double]

    // Gating state — identical semantics to the scalar engine.
    private let hopFrames: Int
    private let hopsPerBlock = 4
    private var hopChannelSumSq: [Double]
    private var hopFramesElapsed = 0
    private var hopHistorySS: [[Double]]
    private var hopHistoryFrames: [Int] = []
    private var blockLoudnessEnergies = [Double]()
    private let nfBlockFrames: Int
    private var nfBlockMonoSumSq: Double = 0
    private var nfBlockFramesElapsed = 0
    private var blockRmsValues = [Double]()

    private var sumSquares: Double = 0
    private var peak: Double = 0
    private var truePeak: Double = 0
    private(set) var totalFrames: Int = 0

    init(format: AVAudioFormat, noiseFloorHighPassHz: Double, chunkCapacity: Int) {
        channels = Int(format.channelCount)
        sr = format.sampleRate
        capacity = chunkCapacity

        let kw = KWeightCoeffs(sampleRate: sr)
        stage1Coeffs = [kw.pre_b0, kw.pre_b1, kw.pre_b2, kw.pre_a1, kw.pre_a2]
        stage2Coeffs = [kw.hp_b0, kw.hp_b1, kw.hp_b2, kw.hp_a1, kw.hp_a2]
        let nfHp = NoiseFloorHPF(sampleRate: sr, cutoffHz: noiseFloorHighPassHz)
        nfCoeffs = [nfHp.b0, nfHp.b1, nfHp.b2, nfHp.a1, nfHp.a2]

        let padded = chunkCapacity + 2
        xBuf = Array(repeating: [Double](repeating: 0, count: padded), count: channels)
        y1Buf = Array(repeating: [Double](repeating: 0, count: padded), count: channels)
        y2Buf = Array(repeating: [Double](repeating: 0, count: padded), count: channels)
        monoF = [Float](repeating: 0, count: chunkCapacity)
        monoD = [Double](repeating: 0, count: padded)
        nfBuf = [Double](repeating: 0, count: padded)
        mids = [Double](repeating: 0, count: chunkCapacity)

        hopFrames = max(1, Int((sr * 0.1).rounded()))
        hopChannelSumSq = [Double](repeating: 0, count: channels)
        hopHistorySS = Array(repeating: [], count: channels)
        nfBlockFrames = max(1, Int((sr * 0.4).rounded()))
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard let channelData = buffer.floatChannelData else {
            throw ProcessingError.analysisError("Could not access channel data")
        }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        guard n <= capacity else {
            throw ProcessingError.analysisError("Analysis chunk exceeds buffer capacity")
        }
        let count = vDSP_Length(n)

        // Per-channel: convert to double, track peaks, run the K-weighting
        // cascade. History slots [0..1] carry the previous chunk's tail.
        for ch in 0..<channels {
            xBuf[ch].withUnsafeMutableBufferPointer { x in
                vDSP_vspdp(channelData[ch], 1, x.baseAddress! + 2, 1, count)

                var chunkPeak = 0.0
                vDSP_maxmgvD(x.baseAddress! + 2, 1, &chunkPeak, count)
                peak = max(peak, chunkPeak)
                truePeak = max(truePeak, chunkPeak)

                // ISP estimate: midpoints of adjacent samples, including the
                // chunk-boundary pair via the history slot. Before any history
                // exists the slot is zero and its phantom midpoint is ≤ |x[0]|/2,
                // which can never exceed the sample peak already tracked — so it
                // matches the scalar engine's hasLastSample skip.
                mids.withUnsafeMutableBufferPointer { m in
                    vDSP_vaddD(x.baseAddress! + 1, 1, x.baseAddress! + 2, 1, m.baseAddress!, 1, count)
                    var half = 0.5
                    vDSP_vsmulD(m.baseAddress!, 1, &half, m.baseAddress!, 1, count)
                    var midPeak = 0.0
                    vDSP_maxmgvD(m.baseAddress!, 1, &midPeak, count)
                    truePeak = max(truePeak, midPeak)
                }
            }

            // Stage 1 pre-filter, then stage 2 RLB weighting. y1's history
            // slots double as the stage-2 input history.
            xBuf[ch].withUnsafeBufferPointer { x in
                y1Buf[ch].withUnsafeMutableBufferPointer { y1 in
                    vDSP_deq22D(x.baseAddress!, 1, stage1Coeffs, y1.baseAddress!, 1, count)
                }
            }
            y1Buf[ch].withUnsafeBufferPointer { y1 in
                y2Buf[ch].withUnsafeMutableBufferPointer { y2 in
                    vDSP_deq22D(y1.baseAddress!, 1, stage2Coeffs, y2.baseAddress!, 1, count)
                }
            }
        }

        // Mono mixdown in Float — same accumulation order and division as the
        // scalar engine (sum channels, divide by count) so rounding matches.
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
        monoD.withUnsafeMutableBufferPointer { md in
            monoF.withUnsafeBufferPointer { m in
                vDSP_vspdp(m.baseAddress!, 1, md.baseAddress! + 2, 1, count)
            }
            var chunkSumSq = 0.0
            vDSP_svesqD(md.baseAddress! + 2, 1, &chunkSumSq, count)
            sumSquares += chunkSumSq
        }

        // Noise-floor HPF on the mono path.
        monoD.withUnsafeBufferPointer { md in
            nfBuf.withUnsafeMutableBufferPointer { nf in
                vDSP_deq22D(md.baseAddress!, 1, nfCoeffs, nf.baseAddress!, 1, count)
            }
        }

        // Hop / noise-floor block accumulation in boundary-aligned segments —
        // the emission logic is the scalar engine's, applied per segment
        // instead of per frame, so blocks land on exactly the same frames.
        var offset = 0
        while offset < n {
            let seg = min(n - offset, hopFrames - hopFramesElapsed, nfBlockFrames - nfBlockFramesElapsed)
            let segCount = vDSP_Length(seg)

            for ch in 0..<channels {
                y2Buf[ch].withUnsafeBufferPointer { y2 in
                    var s = 0.0
                    vDSP_svesqD(y2.baseAddress! + 2 + offset, 1, &s, segCount)
                    hopChannelSumSq[ch] += s
                }
            }
            nfBuf.withUnsafeBufferPointer { nf in
                var s = 0.0
                vDSP_svesqD(nf.baseAddress! + 2 + offset, 1, &s, segCount)
                nfBlockMonoSumSq += s
            }

            hopFramesElapsed += seg
            nfBlockFramesElapsed += seg
            offset += seg

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

        // Carry the last two samples of every filter I/O stream as the next
        // chunk's history. (For n == 1 this correctly shifts by one.)
        for ch in 0..<channels {
            xBuf[ch][0] = xBuf[ch][n]
            xBuf[ch][1] = xBuf[ch][n + 1]
            y1Buf[ch][0] = y1Buf[ch][n]
            y1Buf[ch][1] = y1Buf[ch][n + 1]
            y2Buf[ch][0] = y2Buf[ch][n]
            y2Buf[ch][1] = y2Buf[ch][n + 1]
        }
        monoD[0] = monoD[n]
        monoD[1] = monoD[n + 1]
        nfBuf[0] = nfBuf[n]
        nfBuf[1] = nfBuf[n + 1]

        totalFrames += n
    }

    mutating func finish() throws -> AudioStats {
        // BS.1770 integrated loudness is undefined below one full 400 ms
        // gating block; an empty block list yields the −144.0 sentinel.
        if nfBlockFramesElapsed > 0 {
            let nfRms = sqrt(nfBlockMonoSumSq / Double(nfBlockFramesElapsed))
            blockRmsValues.append(nfRms)
            nfBlockFramesElapsed = 0
        }

        guard totalFrames > 0 else {
            throw ProcessingError.analysisError("No frames to process")
        }

        let rms = sqrt(sumSquares / Double(totalFrames))
        let rmsDb = 20 * log10(max(rms, 1e-12))
        let peakDb = 20 * log10(max(peak, 1e-12))
        let truePeakDb = 20 * log10(max(truePeak, 1e-12))
        let crestDb = peakDb - rmsDb
        let lufs = AudioAnalyzer.computeGatedLUFS(blockEnergies: blockLoudnessEnergies)

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
        // Numerator b = [1, −2, 1] — unnormalized, matching the pyloudnorm reference
        // and ITU-R BS.1770. Dividing by d2 (as was done previously) reduces the
        // overall gain by ~1/d2, producing LUFS ~0.04–0.05 LU below the reference
        // in a rate-dependent way. The denominator is correctly normalized by d2.
        hp_b0 =  1.0
        hp_b1 = -2.0
        hp_b2 =  1.0
        hp_a1 = 2 * (Khsq - 1) / d2
        hp_a2 = (1 - Kh / Q + Khsq) / d2
    }
}
