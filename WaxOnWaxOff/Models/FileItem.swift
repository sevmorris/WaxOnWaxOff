import Foundation

struct FileInfo: Sendable, Equatable {
    let format: String
    let sampleRate: Double
    let channelCount: Int
    let bitDepth: Int?
    let duration: TimeInterval
    let bitRate: Double?
}

struct AudioStats: Equatable, Sendable {
    let rms: Double
    /// Sample peak (dBFS) — max absolute sample value.
    let peak: Double
    /// Inter-sample peak *lower bound* from 2× linear interpolation between
    /// adjacent samples. This is NOT a BS.1770-compliant true-peak measurement
    /// (which requires 4× polyphase oversampling); a linear midpoint can
    /// significantly underestimate true peak on near-Nyquist content. Use the
    /// `measured_TP` value FFmpeg's loudnorm prints to the processing log for
    /// a broadcast-accurate number. Surfaced in the UI as "ISP (est.)" only
    /// when this estimate exceeds the sample peak — i.e., when there is
    /// detectable energy between samples.
    let truePeak: Double
    let crest: Double
    let lufs: Double
    /// Estimated noise floor in dBFS (10th percentile of block RMS values).
    /// nil if not enough blocks to estimate.
    let noiseFloor: Double?

    init(
        rms: Double,
        peak: Double,
        crest: Double,
        lufs: Double,
        noiseFloor: Double? = nil,
        truePeak: Double? = nil
    ) {
        self.rms = rms
        self.peak = peak
        self.truePeak = truePeak ?? peak
        self.crest = crest
        self.lufs = lufs
        self.noiseFloor = noiseFloor
    }

    /// True when the 2× linear ISP estimate exceeds the sample peak by a
    /// visible margin — a hint that inter-sample peaks may be present.
    /// Lower bound only; real true peak may be higher than this estimate.
    var hasElevatedTruePeak: Bool {
        truePeak > peak + 0.1
    }
}

enum FileStatus: Equatable, Sendable {
    case pending
    case analyzing
    case processing
    case ready(AudioStats)
    case processed(outputURL: URL)
    case error(String)
}

struct FileItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var status: FileStatus
    var waveform: WaveformData?
    var outputWaveform: WaveformData?
    var analysisStats: AudioStats?
    var fileInfo: FileInfo?
    var outputStats: AudioStats?
    var outputFileInfo: FileInfo?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.status = .pending
        self.waveform = nil
        self.analysisStats = nil
        self.fileInfo = nil
    }

    var stats: AudioStats? {
        if case .ready(let stats) = status { return stats }
        return analysisStats
    }

    var isProcessed: Bool {
        if case .processed = status { return true }
        return false
    }

    var outputURL: URL? {
        if case .processed(let url) = status { return url }
        return nil
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.analysisStats == rhs.analysisStats && lhs.waveform == rhs.waveform && lhs.outputWaveform == rhs.outputWaveform && lhs.fileInfo == rhs.fileInfo && lhs.outputStats == rhs.outputStats && lhs.outputFileInfo == rhs.outputFileInfo
    }
}
