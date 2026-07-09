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
final class ProcessingLog {
    var entries: [LogEntry] = []

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. this is owned by the WaxOn/WaxOff view models and released with
    // them when the window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    func append(_ message: String, level: LogLevel = .info) {
        entries.append(LogEntry(message: message, level: level))
    }

    func clear() {
        entries.removeAll()
    }
}
