import Foundation

extension FileManager {
    /// App-scoped scratch directory inside NSTemporaryDirectory.
    /// Only the running session's PID-scoped directory is purged at launch;
    /// orphans from a force-quit in a different PID persist until the OS
    /// reclaims /tmp (~3 days). Safe to write temp files here without
    /// polluting the user's output directories.
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
