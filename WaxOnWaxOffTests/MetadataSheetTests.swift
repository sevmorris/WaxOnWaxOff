import XCTest
@testable import WaxOnWaxOff

/// Covers the pure static helpers on `MetadataSheet`. The sheet itself is not
/// presentable until the toolbar button exists, but these are where the user's
/// chapter data can actually be corrupted, so they are worth pinning down now.
final class MetadataSheetTests: XCTestCase {

    // MARK: - text(from:)

    func testEmptyChaptersRenderEmptyString() {
        XCTAssertEqual(MetadataSheet.text(from: []), "")
    }

    func testRendersMinutesAndSecondsBelowOneHour() {
        let text = MetadataSheet.text(from: [
            Chapter(start: 0, title: "Cold open"),
            Chapter(start: 65, title: "Intro"),
            Chapter(start: 3599, title: "Last minute")
        ])
        XCTAssertEqual(text, """
        00:00 Cold open
        01:05 Intro
        59:59 Last minute
        """)
    }

    func testRendersHoursAtOrAboveOneHour() {
        let text = MetadataSheet.text(from: [
            Chapter(start: 3600, title: "Hour mark"),
            Chapter(start: 3661, title: "Just after"),
            Chapter(start: 7325, title: "Second hour")
        ])
        XCTAssertEqual(text, """
        01:00:00 Hour mark
        01:01:01 Just after
        02:02:05 Second hour
        """)
    }

    /// The important one. `text(from:)` and `ChapterParser.parse` must be exact
    /// inverses: the sheet renders stored chapters into the text box on open and
    /// re-parses that text on every keystroke, so any disagreement silently
    /// rewrites the user's chapters the moment they reopen the sheet.
    func testRoundTripsThroughChapterParser() throws {
        let original = [
            Chapter(start: 0, title: "Cold open"),
            Chapter(start: 59, title: "Titles"),
            Chapter(start: 60, title: "Interview — part one"),
            Chapter(start: 3599, title: "Break"),
            Chapter(start: 3600, title: "Interview: part two"),
            Chapter(start: 7325, title: "Outro 2/3 (with punctuation!)")
        ]

        let text = MetadataSheet.text(from: original)
        let parsed = try ChapterParser.parse(text, duration: 10_000).get()

        XCTAssertEqual(parsed.map(\.start), original.map(\.start))
        XCTAssertEqual(parsed.map(\.title), original.map(\.title))
    }

    /// The sheet parses with `.greatestFiniteMagnitude` while a file is still
    /// being analyzed, so the round trip has to hold under that limit too — a
    /// zero default would reject every line instead.
    func testRoundTripsWithUnboundedDuration() throws {
        let original = [
            Chapter(start: 10, title: "One"),
            Chapter(start: 20, title: "Two")
        ]
        let parsed = try ChapterParser.parse(
            MetadataSheet.text(from: original),
            duration: .greatestFiniteMagnitude
        ).get()

        XCTAssertEqual(parsed.map(\.start), original.map(\.start))
        XCTAssertEqual(parsed.map(\.title), original.map(\.title))
    }

    /// Fractional starts round to whole seconds on the way out. They cannot come
    /// from the parser, but they can come from anywhere else that builds a
    /// `Chapter`, and rounding must not produce an unparsable stamp.
    func testFractionalStartsRoundToWholeSeconds() throws {
        let text = MetadataSheet.text(from: [
            Chapter(start: 0.4, title: "Down"),
            Chapter(start: 61.6, title: "Up")
        ])
        XCTAssertEqual(text, "00:00 Down\n01:02 Up")

        let parsed = try ChapterParser.parse(text, duration: 1_000).get()
        XCTAssertEqual(parsed.map(\.start), [0, 62])
    }

    /// `Int(TimeInterval)` traps outside Int's range, and `text(from:)` runs on
    /// data the view did not necessarily produce. Clamping must keep it alive.
    func testAbsurdStartsDoNotTrap() {
        let text = MetadataSheet.text(from: [
            Chapter(start: -5, title: "Negative"),
            Chapter(start: .greatestFiniteMagnitude, title: "Huge"),
            Chapter(start: .infinity, title: "Infinite")
        ])
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        XCTAssertTrue(text.hasPrefix("00:00 Negative"))
    }

    /// One chapter must render as exactly one line. A title carrying a newline
    /// would otherwise be split back into a chapter plus a malformed line,
    /// turning a valid list into a parse error the user cannot see the cause of.
    func testNewlineInTitleDoesNotSplitAChapter() throws {
        let text = MetadataSheet.text(from: [
            Chapter(start: 0, title: "Two\nlines"),
            Chapter(start: 30, title: "Carriage\r\nreturn"),
            Chapter(start: 60, title: "Fine")
        ])
        XCTAssertEqual(text.split(separator: "\n").count, 3)

        let parsed = try ChapterParser.parse(text, duration: 1_000).get()
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.map(\.title), ["Two lines", "Carriage return", "Fine"])
    }

    // MARK: - preservingIdentity(of:in:)

    /// `ChapterParser.parse` mints fresh ids on every call and the sheet
    /// reparses on every keystroke, so unchanged chapters must keep their
    /// identity or the chapter table's rows churn under the user's cursor.
    func testUnchangedChaptersKeepTheirIdentity() {
        let previous = [
            Chapter(start: 0, title: "One"),
            Chapter(start: 60, title: "Two")
        ]
        let reparsed = [
            Chapter(start: 0, title: "One"),
            Chapter(start: 60, title: "Two")
        ]

        // The two arrays are built separately, so `reparsed` carries fresh ids
        // exactly as a real reparse would. Preserving means adopting the old ones.
        XCTAssertNotEqual(reparsed.map(\.id), previous.map(\.id))

        let result = MetadataSheet.preservingIdentity(of: previous, in: reparsed)
        XCTAssertEqual(result.map(\.id), previous.map(\.id))
    }

    func testEditingOneTitleChangesOnlyThatChaptersIdentity() {
        let previous = [
            Chapter(start: 0, title: "One"),
            Chapter(start: 60, title: "Two"),
            Chapter(start: 120, title: "Three")
        ]
        let reparsed = [
            Chapter(start: 0, title: "One"),
            Chapter(start: 60, title: "Two, edited"),
            Chapter(start: 120, title: "Three")
        ]

        let result = MetadataSheet.preservingIdentity(of: previous, in: reparsed)
        XCTAssertEqual(result[0].id, previous[0].id)
        XCTAssertNotEqual(result[1].id, previous[1].id)
        XCTAssertEqual(result[2].id, previous[2].id)
        XCTAssertEqual(result.map(\.title), reparsed.map(\.title))
    }

    /// Matching is by content, not position: a chapter that moves carries its
    /// identity with it rather than handing it to whatever now sits in its slot.
    /// `ChapterParser` would not itself emit this order — it rejects descending
    /// times — but the function must not quietly depend on that.
    func testReorderingPreservesIdentity() {
        let first = Chapter(start: 0, title: "Intro")
        let second = Chapter(start: 60, title: "Outro")
        let previous = [first, second]
        let reparsed = [
            Chapter(start: 60, title: "Outro"),
            Chapter(start: 0, title: "Intro")
        ]

        let result = MetadataSheet.preservingIdentity(of: previous, in: reparsed)
        XCTAssertEqual(result[0].id, second.id)
        XCTAssertEqual(result[1].id, first.id)
    }

    /// Duplicate rows must not both adopt the same id — SwiftUI collapses
    /// `ForEach` rows that share an identity, so one of the two would vanish.
    func testDuplicatePairDoesNotReuseOneIdentityTwice() {
        let previous = [Chapter(start: 0, title: "Same")]
        let reparsed = [
            Chapter(start: 0, title: "Same"),
            Chapter(start: 0, title: "Same")
        ]

        let result = MetadataSheet.preservingIdentity(of: previous, in: reparsed)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, previous[0].id, "the first claims the existing id")
        XCTAssertNotEqual(result[1].id, previous[0].id, "the second must get a fresh one")
        XCTAssertEqual(Set(result.map(\.id)).count, 2, "ids must stay unique")
    }

    /// Two previously-distinct duplicates keep both of their ids rather than
    /// one being dropped and re-minted.
    func testTwoExistingDuplicatesBothKeepTheirIdentities() {
        let previous = [
            Chapter(start: 0, title: "Same"),
            Chapter(start: 0, title: "Same")
        ]
        let reparsed = [
            Chapter(start: 0, title: "Same"),
            Chapter(start: 0, title: "Same")
        ]

        let result = MetadataSheet.preservingIdentity(of: previous, in: reparsed)
        XCTAssertEqual(Set(result.map(\.id)), Set(previous.map(\.id)))
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }

    func testPreservingIdentityAgainstEmptyPreviousReturnsParsedUnchanged() {
        let reparsed = [Chapter(start: 0, title: "One")]
        let result = MetadataSheet.preservingIdentity(of: [], in: reparsed)
        XCTAssertEqual(result.map(\.id), reparsed.map(\.id))
    }

    func testClearingAllTextYieldsNoChapters() {
        let previous = [Chapter(start: 0, title: "One")]
        XCTAssertTrue(MetadataSheet.preservingIdentity(of: previous, in: []).isEmpty)
    }

    /// The whole point, end to end: render chapters to text, parse them back the
    /// way `reparse()` does, and confirm identity survives the trip.
    func testIdentitySurvivesAFullRenderParseCycle() throws {
        let previous = [
            Chapter(start: 0, title: "Cold open"),
            Chapter(start: 3600, title: "Second hour")
        ]
        let parsed = try ChapterParser.parse(
            MetadataSheet.text(from: previous),
            duration: .greatestFiniteMagnitude
        ).get()

        let result = MetadataSheet.preservingIdentity(of: previous, in: parsed)
        XCTAssertEqual(result.map(\.id), previous.map(\.id))
        XCTAssertEqual(result.map(\.start), previous.map(\.start))
        XCTAssertEqual(result.map(\.title), previous.map(\.title))
    }
}
