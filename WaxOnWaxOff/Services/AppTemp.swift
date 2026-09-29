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

    /// Moves `source` to `destination`, guaranteeing no partial file is left at
    /// `destination` if the transfer fails mid-way.
    ///
    /// Same-volume: an atomic rename. Different volumes (external drive, secondary
    /// disk): copies `source` to a dot-prefixed UUID temp inside the destination
    /// directory (same volume as `destination`), then atomically renames that temp
    /// into place. The destination-side temp is removed before any error propagates.
    ///
    /// A file already at `destination` is overwritten, but only in that final step:
    /// it is swapped out by `replaceItemAt` rather than removed ahead of the move, so
    /// a transfer that fails leaves it exactly as it was instead of leaving nothing.
    nonisolated static func moveAtomically(at source: URL, to destination: URL) throws {
        let dstDir = destination.deletingLastPathComponent()
        let srcVol = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let dstVol = try? dstDir.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let sameVolume: Bool
        if let s = srcVol, let d = dstVol {
            sameVolume = (s as AnyObject).isEqual(d as AnyObject)
        } else {
            sameVolume = true  // can't determine volumes — fall back to plain rename
        }
        if sameVolume {
            try place(source, at: destination)
        } else {
            // Copy to a hidden temp in the destination directory so the final rename
            // is same-volume and atomic. Clean up the temp on any failure.
            let ext = destination.pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let dstTemp = dstDir.appendingPathComponent(".\(UUID().uuidString)\(suffix)")
            do {
                try FileManager.default.copyItem(at: source, to: dstTemp)
                try place(dstTemp, at: destination)
            } catch {
                try? FileManager.default.removeItem(at: dstTemp)
                throw error
            }
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// The final step of `moveAtomically`: a rename when `destination` is free, an
    /// atomic replace when something is already there. The replace keeps only the
    /// new file's metadata, as removing the old file and moving the new one did.
    private nonisolated static func place(_ item: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: item, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: item, to: destination)
        }
    }
}
