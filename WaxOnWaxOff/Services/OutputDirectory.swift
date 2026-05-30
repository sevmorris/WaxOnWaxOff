import Foundation

enum OutputNaming {
    /// Short hash tag when multiple inputs would collide on the same output basename.
    nonisolated static func shortPathTag(for path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%06x", hash & 0xFFFFFF)
    }
}

enum OutputDirectory {
    /// Resolve where a WaxOn output WAV should land — mirrors AudioProcessor fallback chain.
    static func waxOnOutputDirectory(
        for input: URL,
        settings: WaxOnSettings,
        onWarning: ((String) -> Void)? = nil
    ) -> URL {
        let fm = FileManager.default

        if let customPath = settings.outputDirectoryPath {
            let customURL = URL(fileURLWithPath: customPath, isDirectory: true)
            if fm.isWritableFile(atPath: customURL.path) { return customURL }
            onWarning?("Custom output directory not writable (\(customPath)), falling back.")
        }

        let here = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: here.path) { return here }

        onWarning?("Source directory not writable, falling back to ~/Music/WaxOnWaxOff.")
        let music = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/WaxOnWaxOff", isDirectory: true)
        if (try? fm.createDirectory(at: music, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: music.path) {
            return music
        }

        onWarning?("~/Music/WaxOnWaxOff unavailable, falling back to Desktop.")
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Resolve where WaxOff delivery files should land — mirrors WaxOn fallback chain.
    static func waxOffOutputDirectory(
        for input: URL,
        settings: WaxOffSettings,
        onWarning: ((String) -> Void)? = nil
    ) -> URL {
        let fm = FileManager.default

        if let customPath = settings.outputDirectoryPath {
            let customURL = URL(fileURLWithPath: customPath, isDirectory: true)
            if fm.isWritableFile(atPath: customURL.path) { return customURL }
            onWarning?("Custom output directory not writable (\(customPath)), falling back.")
        }

        let here = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: here.path) { return here }

        onWarning?("Source directory not writable, falling back to ~/Music/WaxOnWaxOff.")
        let music = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/WaxOnWaxOff", isDirectory: true)
        if (try? fm.createDirectory(at: music, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: music.path) {
            return music
        }

        onWarning?("~/Music/WaxOnWaxOff unavailable, falling back to Desktop.")
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
