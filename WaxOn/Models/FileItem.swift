import Foundation

struct AudioStats: Equatable, Sendable {
    let rms: Double
    let peak: Double
    let crest: Double
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

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.status = .pending
        self.waveform = nil
        self.analysisStats = nil
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
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.analysisStats == rhs.analysisStats && lhs.waveform?.peaks.count == rhs.waveform?.peaks.count && lhs.outputWaveform?.peaks.count == rhs.outputWaveform?.peaks.count
    }
}
