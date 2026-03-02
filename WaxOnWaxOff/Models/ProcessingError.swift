import Foundation

struct JobResult: Sendable {
    let id: UUID?
    let input: URL
    let output: URL

    nonisolated init(id: UUID? = nil, input: URL, output: URL) {
        self.id = id
        self.input = input
        self.output = output
    }
}

enum ProcessingError: LocalizedError {
    case invalidInput
    case tempDirectoryFailed
    case ffmpegNotFound
    case ffmpegFailed(code: Int32, message: String)
    case outputMissing
    case analysisError(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid input file"
        case .tempDirectoryFailed:
            return "Failed to create temporary directory"
        case .ffmpegNotFound:
            return "FFmpeg executable not found"
        case .ffmpegFailed(let code, let message):
            return "FFmpeg failed (\(code)): \(message)"
        case .outputMissing:
            return "Processing produced no output"
        case .analysisError(let message):
            return "Audio analysis failed: \(message)"
        }
    }
}
