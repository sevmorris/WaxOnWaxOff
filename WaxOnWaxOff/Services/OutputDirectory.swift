import Foundation

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

    static func waxOffOutputDirectory(for input: URL, settings: WaxOffSettings) -> URL {
        if let customPath = settings.outputDirectoryPath {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        return input.deletingLastPathComponent()
    }
}
