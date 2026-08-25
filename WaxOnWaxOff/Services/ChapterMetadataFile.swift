import Foundation

/// Builds the ffmetadata file that carries chapters into FFmpeg via
/// `-map_chapters`. Contains only `[CHAPTER]` blocks — title and album travel
/// as `-metadata` arguments so there is never a precedence question between
/// this file's global section and `-map_metadata 0`.
enum ChapterMetadataFile {

    /// Escapes a value for the ffmetadata format. The backslash substitution
    /// must run first, otherwise the backslashes introduced by the later
    /// substitutions would themselves be escaped. For example "A\=B" must
    /// become "A\\\=B" (backslash doubled, then the equals gets its own
    /// escape) — not "A\\=B" (equals left unescaped, corrupting the parse)
    /// and not "A\\\\=B" (the escaping backslash re-escaped a second time).
    private static func escape(_ value: String) -> String {
        var out = value.replacingOccurrences(of: #"\"#, with: #"\\"#)
        for character in ["=", ";", "#"] {
            out = out.replacingOccurrences(of: character, with: #"\"# + character)
        }
        // A raw newline ends the value; a backslash continues it to the next line.
        out = out.replacingOccurrences(of: "\n", with: #"\"# + "\n")
        return out
    }

    /// Converts seconds to milliseconds for the TIMEBASE=1/1000 clock, without
    /// ever trapping. `Int(_:)` on a `Double` crashes the process if the value
    /// is NaN, infinite, or simply too large to fit — Task 2's parser bounds
    /// the timestamps it produces, but this function is `enum`-static API
    /// with no such guarantee from its caller, so it has to defend itself.
    /// Chapter timestamps are never legitimately negative, so negative and NaN
    /// inputs collapse to 0; +infinity and finite-but-unrepresentable values
    /// saturate to `Int.max` rather than propagate garbage into the
    /// ffmetadata file that FFmpeg would then have to reject.
    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return seconds == .infinity ? Int.max : 0 }
        guard seconds > 0 else { return 0 }
        let ms = (seconds * 1000).rounded()
        guard ms < Double(Int.max) else { return Int.max }
        return Int(ms)
    }

    /// Chapter *i* ends where *i+1* begins; the last ends at `duration`.
    ///
    /// - Precondition: `chapters` is sorted ascending by `start`, with no two
    ///   chapters sharing a start and none starting at or after `duration`.
    ///   `ChapterParser` guarantees all three, and `DeliveryProcessor` filters
    ///   out-of-range chapters before calling. This function does not re-check
    ///   or re-sort: an unsorted list yields blocks whose END precedes their
    ///   START, which is a caller bug worth surfacing rather than quietly
    ///   repairing. Deliberately unlike `milliseconds(_:)` above, which does
    ///   clamp — that guards against a trap that would kill the process, where
    ///   this only produces a bad file.
    static func contents(for chapters: [Chapter], duration: TimeInterval) -> String {
        var lines = [";FFMETADATA1"]

        for (index, chapter) in chapters.enumerated() {
            let endSeconds = index + 1 < chapters.count ? chapters[index + 1].start : duration
            let startMS = milliseconds(chapter.start)
            let endMS = milliseconds(endSeconds)
            lines += [
                "[CHAPTER]",
                "TIMEBASE=1/1000",
                "START=\(startMS)",
                "END=\(endMS)",
                "title=\(escape(chapter.title))"
            ]
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the file into `directory` under a unique name and returns its URL.
    /// The caller owns cleanup. The name is UUID-derived so concurrent
    /// deliveries (or a second delivery of the same episode before the first's
    /// temp file is cleaned up) never collide on the same path.
    static func write(chapters: [Chapter], duration: TimeInterval, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("chapters_\(UUID().uuidString.prefix(8)).txt")
        try contents(for: chapters, duration: duration).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
