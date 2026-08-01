import Foundation
import AppKit

enum OutputNaming {
    /// WaxOn prep outputs: `{name}-{44k|48k}waxon.wav`
    nonisolated static func looksLikeWaxOnPrep(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        return base.range(of: #"\d{2}kwaxon"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// WaxOff delivery outputs: `{name}-lev{target}LUFS.{wav,mp3}` (target includes sign).
    nonisolated static func looksLikeWaxOffDelivery(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        return base.range(
            of: #"-lev-?\d+(\.\d+)?LUFS"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

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
    nonisolated static func waxOnOutputDirectory(
        for input: URL,
        settings: WaxOnSettings,
        onWarning: ((String) -> Void)? = nil
    ) -> URL {
        resolve(
            customPath: settings.outputDirectoryPath,
            input: input,
            onWarning: onWarning
        )
    }

    /// Resolve where WaxOff delivery files should land — mirrors WaxOn fallback chain.
    nonisolated static func waxOffOutputDirectory(
        for input: URL,
        settings: WaxOffSettings,
        onWarning: ((String) -> Void)? = nil
    ) -> URL {
        resolve(
            customPath: settings.outputDirectoryPath,
            input: input,
            onWarning: onWarning
        )
    }

    /// Pre-flight check the resolved output directories are writable. Returns
    /// a user-facing error string if any aren't (e.g. when the entire fallback
    /// chain — custom path, source dir, ~/Music/WaxOnWaxOff, ~/Desktop — was
    /// exhausted to a directory we can't actually write to). Returns nil when
    /// every directory in `urls` is OK.
    nonisolated static func unwritableReason(_ urls: [URL]) -> String? {
        let fm = FileManager.default
        let distinct = Array(Set(urls.map(\.path))).sorted()
        for path in distinct {
            if !fm.isWritableFile(atPath: path) {
                return "Output directory is not writable: \(path). Choose a different directory in Settings."
            }
        }
        return nil
    }

    /// If the fallback chain would send more than one output to ~/Desktop,
    /// confirm before proceeding — a silent batch of files on the Desktop is
    /// surprising. Single-file jobs fall back silently (existing behaviour).
    ///
    /// Returns true when the caller should proceed: either fewer than two
    /// outputs land on the Desktop, or the user chose Continue Anyway.
    ///
    /// `@MainActor` because `NSAlert.runModal()` requires it. The rest of this
    /// enum is `nonisolated`; this member is the exception because it presents
    /// UI rather than computing a path.
    @MainActor static func confirmDesktopFallback(outputDirectories: [URL]) -> Bool {
        let desktopPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").path
        let desktopCount = outputDirectories.filter { $0.path == desktopPath }.count
        guard desktopCount > 1 else { return true }

        let alert = NSAlert()
        alert.messageText = "Output will land on your Desktop"
        alert.informativeText = "The app found no other writable directory. The app writes \(desktopCount) output files to ~/Desktop. To prevent this, set a custom output directory in Settings."
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    nonisolated private static func resolve(
        customPath: String?,
        input: URL,
        onWarning: ((String) -> Void)?
    ) -> URL {
        let fm = FileManager.default

        if let customPath {
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

        let desktop = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        if fm.isWritableFile(atPath: desktop.path) {
            onWarning?("~/Music/WaxOnWaxOff unavailable, falling back to Desktop.")
            return desktop
        }
        // Last resort: still return Desktop so existing logic has a URL to
        // work with. The pre-flight check (`unwritableReason`) is responsible
        // for blocking the batch with a clear user-facing message before
        // anything tries to actually write here.
        onWarning?("⚠ No writable output directory found — even ~/Desktop is unavailable. Pick a different output directory in Settings.")
        return desktop
    }
}
