import Foundation

extension FileManager {
    /// App-scoped scratch directory inside NSTemporaryDirectory.
    /// Contents are purged on every app launch; safe to write temp files here
    /// without polluting the user's output directories.
    nonisolated static var waxonTempDirectory: URL {
        // Scoped to the running process's PID so a second app instance launched
        // concurrently cannot delete another instance's in-flight temp files at
        // startup. The path is stable for the lifetime of this process.
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("io.github.sevmorris.WaxOnWaxOff/\(pid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
