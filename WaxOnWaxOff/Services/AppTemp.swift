import Foundation

extension FileManager {
    /// App-scoped scratch directory inside NSTemporaryDirectory.
    /// Contents are purged on every app launch; safe to write temp files here
    /// without polluting the user's output directories.
    nonisolated static var waxonTempDirectory: URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("io.github.sevmorris.WaxOnWaxOff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
