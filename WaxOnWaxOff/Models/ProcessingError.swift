import Foundation

struct JobResult: Sendable {
    let id: UUID?
    let input: URL
    /// Every file this job wrote. One entry normally; two when Channels is set
    /// to Split L/R, in source-channel order (left first).
    let outputs: [URL]

    nonisolated init(id: UUID? = nil, input: URL, outputs: [URL]) {
        precondition(!outputs.isEmpty, "a JobResult must carry at least one output")
        self.id = id
        self.input = input
        self.outputs = outputs
    }
}

struct WaxOnJobFailure: Sendable, Error {
    let id: UUID
    let message: String
}

/// Per-file outcomes from a WaxOn batch — one file failing does not abort the rest.
struct WaxOnBatchRunResult: Sendable {
    let successes: [JobResult]
    let failures: [WaxOnJobFailure]
}

enum ProcessingError: LocalizedError {
    case invalidInput
    case tempDirectoryFailed
    case ffmpegNotFound
    case ffmpegFailed(code: Int32, message: String)
    case outputMissing
    case analysisError(String)
    /// ffprobe ran and the file has no audio stream it can read.
    case noAudioStream
    /// ffprobe itself could not run, so the file was never checked.
    case probeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid input file"
        case .tempDirectoryFailed:
            return "Failed to create temporary directory"
        case .ffmpegNotFound:
            return "FFmpeg executable not found"
        case .ffmpegFailed(let code, let message):
            return "FFmpeg failed with code \(code). \(message)"
        case .outputMissing:
            return "Processing produced no output file."
        case .analysisError(let message):
            return "The audio analysis failed. \(message)"
        case .noAudioStream:
            return "No audio stream found — file may be misnamed or unsupported."
        case .probeFailed(let detail):
            return "The bundled ffprobe failed to run: \(detail). The file was not checked. Update or reinstall WaxOn/WaxOff."
        }
    }
}
