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
    /// Every file the job wrote, in the order the processor produced them.
    /// One entry normally; two when WaxOn's Channels is Split L/R (left first)
    /// or WaxOff's format is Both (WAV first).
    case processed(outputURLs: [URL])
    case error(String)
}

/// One rendered output plus whatever has been measured about it. A row keeps
/// one of these per file the job wrote, so a split or dual-format render can
/// show either side rather than silently dropping all but the first.
struct OutputFile: Identifiable, Equatable {
    let url: URL
    /// Short tag distinguishing this output from its siblings ("L"/"R",
    /// "WAV"/"MP3"). Empty when the job produced a single file.
    let label: String
    var waveform: WaveformData?
    var stats: AudioStats?
    var fileInfo: FileInfo?

    var id: URL { url }

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    /// Short labels that tell a job's outputs apart. Outputs whose extensions
    /// all differ label by extension (WAV / MP3); outputs sharing one label by
    /// the part of the stem that differs (L / R). Falls back to ordinals if
    /// neither yields a distinct set.
    static func labels(for urls: [URL]) -> [String] {
        guard urls.count > 1 else { return urls.map { _ in "" } }
        let exts = urls.map { $0.pathExtension.uppercased() }
        if Set(exts).count == urls.count { return exts }

        let stems = urls.map { Array($0.deletingPathExtension().lastPathComponent) }
        let shortest = stems.map(\.count).min() ?? 0
        var prefix = 0
        while prefix < shortest, stems.allSatisfy({ $0[prefix] == stems[0][prefix] }) { prefix += 1 }
        var suffix = 0
        while prefix + suffix < shortest,
              stems.allSatisfy({ $0[$0.count - 1 - suffix] == stems[0][stems[0].count - 1 - suffix] }) {
            suffix += 1
        }
        let separators = CharacterSet(charactersIn: "-_ .")
        let trimmed = stems.map {
            String($0[prefix..<($0.count - suffix)]).trimmingCharacters(in: separators).uppercased()
        }
        // Collision disambiguation can leave a long diff ("L-A1B2C3"); its
        // leading component is still the part that tells the outputs apart.
        let heads = trimmed.map { $0.split(separator: "-").first.map(String.init) ?? $0 }
        if !heads.contains(where: \.isEmpty), Set(heads).count == urls.count,
           heads.allSatisfy({ $0.count <= 4 }) {
            return heads
        }
        guard !trimmed.contains(where: \.isEmpty), Set(trimmed).count == urls.count else {
            return urls.indices.map { String($0 + 1) }
        }
        return trimmed
    }
}

struct FileItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var status: FileStatus
    var waveform: WaveformData?
    var analysisStats: AudioStats?
    var fileInfo: FileInfo?
    /// Populated when the job completes — one entry per file it wrote.
    var outputs: [OutputFile] = []
    /// Which of `outputs` the detail pane is showing.
    var selectedOutputIndex: Int = 0

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

    /// Everything the job wrote, for Finder reveal and multi-output UI.
    var outputURLs: [URL] {
        if case .processed(let urls) = status { return urls }
        return []
    }

    /// The output the detail pane is showing, once its analysis has landed.
    var selectedOutput: OutputFile? {
        outputs.indices.contains(selectedOutputIndex) ? outputs[selectedOutputIndex] : outputs.first
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.analysisStats == rhs.analysisStats && lhs.waveform == rhs.waveform && lhs.fileInfo == rhs.fileInfo && lhs.outputs == rhs.outputs && lhs.selectedOutputIndex == rhs.selectedOutputIndex
    }
}
