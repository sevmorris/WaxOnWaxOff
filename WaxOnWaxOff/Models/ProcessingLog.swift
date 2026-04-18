import Foundation
import Observation

enum LogLevel {
    case info
    case verbose
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
}

@Observable
@MainActor
final class ProcessingLog: @unchecked Sendable {
    var entries: [LogEntry] = []

    func append(_ message: String, level: LogLevel = .info) {
        entries.append(LogEntry(message: message, level: level))
    }

    func clear() {
        entries.removeAll()
    }
}
