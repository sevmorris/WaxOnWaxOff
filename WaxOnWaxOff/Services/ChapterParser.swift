import Foundation

enum ChapterParseError: Error, Equatable, LocalizedError {
    /// The line is not `MM:SS Title` or `HH:MM:SS Title`.
    case malformedLine(number: Int, text: String)
    /// The line is a valid timestamp with no title after it.
    case missingTitle(number: Int, text: String)
    /// The timestamp is not later than the previous chapter's.
    case outOfOrder(number: Int)
    /// The timestamp is at or past the end of the audio.
    case beyondDuration(number: Int, start: TimeInterval, duration: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .malformedLine(let number, let text):
            return "Line \(number) is not a chapter. Use MM:SS Title or HH:MM:SS Title. Found: \"\(text)\""
        case .missingTitle(let number, let text):
            return "Line \(number) has a time but no chapter title. Add a title after the time. Found: \"\(text)\""
        case .outOfOrder(let number):
            return "Line \(number) is not later than the chapter before it. Chapter times must increase."
        case .beyondDuration(let number, let start, let duration):
            return String(format: "Line %d is at %.0f s, which is past the end of the audio (%.0f s).",
                          number, start, duration)
        }
    }
}

/// Parses pasted chapter text into `[Chapter]`. Pure: no I/O, no FFmpeg, no UI.
enum ChapterParser {

    static func parse(_ text: String, duration: TimeInterval) -> Result<[Chapter], ChapterParseError> {
        var chapters: [Chapter] = []

        // Line numbers are 1-based and count every line including blanks, so an
        // error message points at what the user sees in the text box.
        //
        // Split on Character.isNewline rather than CharacterSet.newlines: a
        // CRLF pair is a single Swift Character, so this counts "a\r\nb" as two
        // lines. `components(separatedBy: .newlines)` splits on the CR and the
        // LF separately and yields an empty line between them, which parses the
        // same but shifts every reported line number away from the line the
        // user is looking at. Chapter text is pasted, often from Windows-
        // authored show notes, so CRLF is expected input rather than an edge case.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            guard let split = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                // A line that is nothing but a valid timestamp is a missing
                // title, not an unrecognisable line. Saying "this is not a
                // chapter" about a well-formed time is actively misleading.
                if seconds(from: line) != nil {
                    return .failure(.missingTitle(number: lineNumber, text: line))
                }
                return .failure(.malformedLine(number: lineNumber, text: line))
            }
            let stamp = String(line[line.startIndex..<split])
            let title = String(line[split...]).trimmingCharacters(in: .whitespaces)

            guard !title.isEmpty, let start = seconds(from: stamp) else {
                return .failure(.malformedLine(number: lineNumber, text: line))
            }
            guard start < duration else {
                return .failure(.beyondDuration(number: lineNumber, start: start, duration: duration))
            }
            if let previous = chapters.last, start <= previous.start {
                return .failure(.outOfOrder(number: lineNumber))
            }
            chapters.append(Chapter(start: start, title: title))
        }

        // No sort: the outOfOrder guard above rejects any line whose start is
        // not strictly greater than the previous one, so the array is already
        // ordered by construction. Sorting here would suggest a case exists
        // that this function does not actually allow.
        return .success(chapters)
    }

    /// No audio file runs for a million minutes. Each component is bounded
    /// before the multiplications below because `Int("9999999999999999")`
    /// parses cleanly and only traps when multiplied by 3600 — and Swift's
    /// `*` traps rather than wrapping. This function's whole job is to turn
    /// bad input into nil instead of a crash, and it re-parses on every
    /// keystroke in the chapter text box, so a trap here takes the app down
    /// while the user is still typing.
    private static let maxTimeComponent = 1_000_000

    /// `MM:SS` or `HH:MM:SS` to seconds. Seconds are always 0–59; minutes are
    /// 0–59 only in the three-part form, so `90:00` reads as ninety minutes.
    private static func seconds(from stamp: String) -> TimeInterval? {
        let parts = stamp.components(separatedBy: ":")
        // Two checks, deliberately. `Character.isNumber` accepts non-ASCII
        // digits (Arabic-Indic ٠١٢, mathematical bold, and others) that
        // `Int.init(String)` rejects, so the count recheck below is what stops
        // compactMap from silently dropping such a component and parsing
        // "٠٠:30" as though the first field were absent. Collapsing these into
        // one pass reintroduces that bug.
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        guard values.allSatisfy({ $0 <= maxTimeComponent }) else { return nil }

        switch values.count {
        case 2:
            let (minutes, secs) = (values[0], values[1])
            guard secs < 60 else { return nil }
            return TimeInterval(minutes * 60 + secs)
        case 3:
            let (hours, minutes, secs) = (values[0], values[1], values[2])
            guard minutes < 60, secs < 60 else { return nil }
            return TimeInterval(hours * 3600 + minutes * 60 + secs)
        default:
            return nil
        }
    }
}
