import XCTest
@testable import WaxOnWaxOff

/// Covers `ChapterTableView`'s pure helpers, and — more importantly — the
/// property the sheet's two-way sync depends on: every edit the table can make
/// leaves `draft.chapters` at a fixpoint of
/// `preservingIdentity(text(from:) → parse)`. If that ever stops holding, the
/// sheet's table → text → parse → chapters loop runs a second pass, which
/// means it can also run a third, which means it can churn ids and tear rows
/// down under the user's cursor.
final class ChapterTableTests: XCTestCase {

    private let unbounded = TimeInterval.greatestFiniteMagnitude

    // MARK: - One timestamp grammar

    func testAcceptsMinutesAndSeconds() {
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "00:00", duration: unbounded), 0)
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "01:30", duration: unbounded), 90)
        // Unpadded input is what a person actually types.
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "1:30", duration: unbounded), 90)
        // Two-part minutes are not capped at 59, matching the parser.
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "90:00", duration: unbounded), 5400)
    }

    func testAcceptsHoursMinutesAndSeconds() {
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "01:00:00", duration: unbounded), 3600)
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "02:02:05", duration: unbounded), 7325)
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "  1:30  ", duration: unbounded), 90)
    }

    /// In-progress input has to come back nil rather than committing something
    /// wrong. The field keeps the text either way; only the model is spared.
    func testRejectsIncompleteAndMalformedStamps() {
        for stamp in ["", " ", "1", "1:", ":30", "1:60", "1:2:3:4", "abc", "-1:00", "1.30"] {
            XCTAssertNil(
                ChapterTableView.seconds(fromStamp: stamp, duration: unbounded),
                "\"\(stamp)\" must not parse as a timestamp"
            )
        }
    }

    /// The parser splits a line at its first space, so handing it
    /// `"1:30 extra x"` would happily read `1:30` as the time and `extra x` as
    /// the title. A stamp field containing a space is not a stamp.
    func testRejectsAStampWithInteriorWhitespace() {
        XCTAssertNil(ChapterTableView.seconds(fromStamp: "1:30 extra", duration: unbounded))
        XCTAssertNil(ChapterTableView.seconds(fromStamp: "1:30\textra", duration: unbounded))
    }

    /// Non-ASCII digits are rejected by the parser and so must be rejected
    /// here — the whole point of routing through it is that there is no second
    /// grammar that could disagree.
    func testRejectsNonASCIIDigitsExactlyAsTheParserDoes() {
        let stamp = "\u{0660}\u{0660}:30"
        XCTAssertNil(ChapterTableView.seconds(fromStamp: stamp, duration: unbounded))
        XCTAssertEqual(
            ChapterParser.parse("\(stamp) x", duration: unbounded),
            .failure(.malformedLine(number: 1, text: "\(stamp) x"))
        )
    }

    /// The duration range check comes along for free, so the table cannot
    /// accept a time the paste box would reject.
    func testAppliesTheDurationRangeCheck() {
        XCTAssertEqual(ChapterTableView.seconds(fromStamp: "01:00", duration: 61), 60)
        XCTAssertNil(ChapterTableView.seconds(fromStamp: "01:00", duration: 60), "start == duration is past the end")
        XCTAssertNil(ChapterTableView.seconds(fromStamp: "01:00", duration: 30))
    }

    // MARK: - stamp(for:)

    /// `stamp(for:)` must render a start exactly the way the paste box does,
    /// or the same chapter reads two different ways on one screen.
    func testStampMatchesTheTextTheSheetWrites() {
        for start in [TimeInterval(0), 5, 59, 60, 65, 3599, 3600, 3661, 7325, 359_999] {
            let line = MetadataSheet.text(from: [Chapter(start: start, title: "T")])
            XCTAssertEqual(ChapterTableView.stamp(for: start) + " T", line)
        }
    }

    func testStampAndSecondsAreInverses() {
        for start in [TimeInterval(0), 1, 59, 60, 90, 3599, 3600, 7325] {
            let stamp = ChapterTableView.stamp(for: start)
            XCTAssertEqual(ChapterTableView.seconds(fromStamp: stamp, duration: unbounded), start, stamp)
        }
    }

    /// `text(from:)` clamps absurd starts rather than trapping; `stamp(for:)`
    /// inherits that and must not crash or return something unparsable.
    func testStampSurvivesAbsurdStarts() {
        XCTAssertEqual(ChapterTableView.stamp(for: -5), "00:00")
        let huge = ChapterTableView.stamp(for: .infinity)
        XCTAssertNotNil(ChapterTableView.seconds(fromStamp: huge, duration: unbounded))
    }

    // MARK: - normalizedTitle

    func testNormalizedTitleTrimsAndFlattens() {
        XCTAssertEqual(ChapterTableView.normalizedTitle("  Intro  "), "Intro")
        XCTAssertEqual(ChapterTableView.normalizedTitle("Two\nlines"), "Two lines")
        XCTAssertEqual(ChapterTableView.normalizedTitle("Carriage\r\nreturn"), "Carriage return")
        XCTAssertEqual(ChapterTableView.normalizedTitle("\tTabbed\t"), "Tabbed")
        XCTAssertEqual(ChapterTableView.normalizedTitle("   "), "")
    }

    /// Interior spacing is the user's business and must survive.
    func testNormalizedTitleKeepsInteriorSpacing() {
        XCTAssertEqual(ChapterTableView.normalizedTitle("Part  one — two"), "Part  one — two")
    }

    func testNormalizedTitleIsIdempotent() {
        for raw in ["  Intro ", "Two\nlines", "Part  one", "Fine"] {
            let once = ChapterTableView.normalizedTitle(raw)
            XCTAssertEqual(ChapterTableView.normalizedTitle(once), once)
        }
    }

    // MARK: - sorted / applying / removing

    func testChangingAStartResortsAndKeepsIdentity() {
        let moved = Chapter(start: 120, title: "Third")
        let chapters = [
            Chapter(start: 0, title: "First"),
            Chapter(start: 60, title: "Second"),
            moved
        ]

        let result = ChapterTableView.applying(start: 30, toChapterWith: moved.id, in: chapters)

        XCTAssertEqual(result.map(\.start), [0, 30, 60])
        XCTAssertEqual(result[1].id, moved.id, "the moved row keeps its identity, and so its drafts and focus")
        XCTAssertEqual(result[1].title, "Third")
        XCTAssertEqual(Set(result.map(\.id)), Set(chapters.map(\.id)), "no row is lost by the move")
    }

    func testMovingTheLastRowForwardKeepsEveryRow() {
        let last = Chapter(start: 300, title: "Outro")
        let chapters = [Chapter(start: 0, title: "A"), Chapter(start: 60, title: "B"), last]
        let result = ChapterTableView.applying(start: 30, toChapterWith: last.id, in: chapters)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.id), [chapters[0].id, last.id, chapters[1].id])
        XCTAssertEqual(result.map(\.start), [0, 30, 60])
    }

    /// A stamp edit passes through equal starts on the way somewhere else, so
    /// the sort has to be stable — an unstable one would swap the two rows for
    /// that keystroke and hand each the other's field contents. Swift
    /// guarantees this (SE-0372); the test is here because the table's
    /// behaviour depends on it, not because the guarantee is in doubt.
    func testSortIsStableForEqualStarts() {
        let first = Chapter(start: 60, title: "First")
        let second = Chapter(start: 60, title: "Second")
        let third = Chapter(start: 60, title: "Third")
        let result = ChapterTableView.sorted([first, second, third])
        XCTAssertEqual(result.map(\.id), [first.id, second.id, third.id])
    }

    func testApplyingToAnUnknownIdChangesNothing() {
        let chapters = [Chapter(start: 0, title: "One")]
        XCTAssertEqual(ChapterTableView.applying(start: 60, toChapterWith: UUID(), in: chapters), chapters)
        XCTAssertEqual(ChapterTableView.applying(title: "x", toChapterWith: UUID(), in: chapters), chapters)
    }

    func testApplyingATitleDoesNotReorder() {
        let a = Chapter(start: 60, title: "A")
        let b = Chapter(start: 60, title: "B")
        let result = ChapterTableView.applying(title: "Renamed", toChapterWith: b.id, in: [a, b])
        XCTAssertEqual(result.map(\.id), [a.id, b.id])
        XCTAssertEqual(result[1].title, "Renamed")
    }

    /// A stamp edit that lands on an existing start must keep both rows in the
    /// order they were already in, across a longer array than the three-element
    /// case above — stability is what stops a row swapping field contents with
    /// a neighbour mid-edit.
    func testSortIsStableAcrossManyEqualStarts() {
        let tied = (0..<200).map { Chapter(start: 60, title: "Row \($0)") }
        let chapters = [Chapter(start: 0, title: "First")] + tied + [Chapter(start: 120, title: "Last")]
        let result = ChapterTableView.sorted(chapters)
        XCTAssertEqual(result.map(\.id), chapters.map(\.id))
    }

    // MARK: - Draft pruning

    func testPruningDropsADraftWhoseRowIsGone() {
        let kept = UUID()
        let removed = UUID()
        let drafts = [kept: "1:3", removed: "9:9"]
        XCTAssertEqual(ChapterTableView.pruned(drafts, keeping: [kept]), [kept: "1:3"])
    }

    func testPruningKeepsDraftsForSurvivingRows() {
        let a = UUID()
        let b = UUID()
        let drafts = [a: "0:0", b: "1:"]
        XCTAssertEqual(ChapterTableView.pruned(drafts, keeping: [a, b]), drafts)
    }

    /// A paste-box edit replaces the array wholesale: `preservingIdentity`
    /// mints a fresh id for every chapter whose text changed, so drafts keyed
    /// to the old ids all have to go.
    func testWholesaleReplacementDropsEveryStaleDraft() {
        let old = [UUID(), UUID(), UUID()]
        let drafts = Dictionary(uniqueKeysWithValues: old.map { ($0, "1:3") })
        let replacement = Set([UUID(), UUID()])
        XCTAssertTrue(ChapterTableView.pruned(drafts, keeping: replacement).isEmpty)
    }

    /// Clearing the paste box removes every row. A time draft surviving that
    /// would hold `timeError` set and Save disabled with no row left to fix.
    func testPruningAgainstNoLiveRowsEmptiesTheDrafts() {
        let drafts = [UUID(): "1:3", UUID(): "nonsense"]
        XCTAssertTrue(ChapterTableView.pruned(drafts, keeping: []).isEmpty)
    }

    func testPruningAnEmptyDictionaryStaysEmpty() {
        XCTAssertTrue(ChapterTableView.pruned([:], keeping: [UUID()]).isEmpty)
        XCTAssertTrue(ChapterTableView.pruned([:], keeping: []).isEmpty)
    }

    func testRemovingARow() {
        let target = Chapter(start: 60, title: "Two")
        let chapters = [Chapter(start: 0, title: "One"), target, Chapter(start: 120, title: "Three")]
        let result = ChapterTableView.removing(id: target.id, from: chapters)
        XCTAssertEqual(result.map(\.title), ["One", "Three"])
        XCTAssertEqual(ChapterTableView.removing(id: UUID(), from: chapters), chapters)
        XCTAssertTrue(ChapterTableView.removing(id: chapters[0].id, from: [chapters[0]]).isEmpty)
    }

    // MARK: - nextStart

    func testFirstAddedChapterStartsAtZero() {
        XCTAssertEqual(ChapterTableView.nextStart(after: [], duration: 600), 0)
        XCTAssertEqual(ChapterTableView.nextStart(after: [], duration: nil), 0)
    }

    func testAddedChapterFollowsTheLastByAMinute() {
        let chapters = [Chapter(start: 0, title: "A"), Chapter(start: 90, title: "B")]
        XCTAssertEqual(ChapterTableView.nextStart(after: chapters, duration: 600), 150)
        XCTAssertEqual(ChapterTableView.nextStart(after: chapters, duration: nil), 150)
    }

    /// A minute would run past the end, but a second still fits, so Add stays
    /// usable on a short file instead of going dead near the end.
    func testAddedChapterFallsBackToOneSecondNearTheEnd() {
        let chapters = [Chapter(start: 100, title: "A")]
        XCTAssertEqual(ChapterTableView.nextStart(after: chapters, duration: 120), 101)
    }

    func testAddIsUnavailableWhenNothingFits() {
        XCTAssertNil(ChapterTableView.nextStart(after: [Chapter(start: 100, title: "A")], duration: 101))
        XCTAssertNil(ChapterTableView.nextStart(after: [], duration: 0))
    }

    /// `text(from:)` clamps at 359_999, so a start beyond it would render as a
    /// different time than it holds and break the round trip.
    func testAddNeverExceedsTheRenderableRange() {
        let chapters = [Chapter(start: 359_998, title: "A")]
        let next = ChapterTableView.nextStart(after: chapters, duration: nil)
        XCTAssertEqual(next, 359_999)
        XCTAssertNil(ChapterTableView.nextStart(after: [Chapter(start: 359_999, title: "A")], duration: nil))
    }

    // MARK: - Error message

    func testTimeErrorMessage() {
        XCTAssertNil(ChapterTableView.timeErrorMessage(invalidCount: 0, hasDuration: true))
        XCTAssertEqual(
            ChapterTableView.timeErrorMessage(invalidCount: 1, hasDuration: true),
            "One chapter time is not a valid timestamp. Use MM:SS or HH:MM:SS, within the file's length."
        )
        // With no duration there is nothing to range-check against, so the
        // message must not claim the file's length is being applied.
        XCTAssertEqual(
            ChapterTableView.timeErrorMessage(invalidCount: 3, hasDuration: false),
            "3 chapter times are not valid timestamps. Use MM:SS or HH:MM:SS."
        )
    }

    // MARK: - The sync converges

    /// Exactly what `MetadataSheet` does after a table write: regenerate the
    /// paste box, let the editor's `onChange` reparse it, and reconcile ids.
    private func syncOnce(
        _ chapters: [Chapter],
        duration: TimeInterval
    ) throws -> (chapters: [Chapter], text: String) {
        let text = MetadataSheet.text(from: chapters)
        let parsed = try ChapterParser.parse(text, duration: duration).get()
        return (MetadataSheet.preservingIdentity(of: chapters, in: parsed), text)
    }

    /// Asserts the loop settles in one pass. `draft.chapters` coming back
    /// *identical* — ids included — is what stops the sheet firing another
    /// round: SwiftUI's `onChange` only fires on a real change, so an equal
    /// value ends the cascade. It also means no row's identity churned, so no
    /// `ForEach` row was torn down and no field lost its contents or focus.
    private func assertConverges(
        _ chapters: [Chapter],
        duration: TimeInterval = 10_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let first = try syncOnce(chapters, duration: duration)
        XCTAssertEqual(first.chapters, chapters, "the sync must be a fixpoint after one pass", file: file, line: line)

        let second = try syncOnce(first.chapters, duration: duration)
        XCTAssertEqual(second.chapters, first.chapters, "a second pass must be a no-op", file: file, line: line)
        XCTAssertEqual(second.text, first.text, "the paste box must stop changing", file: file, line: line)
    }

    func testEditingATimestampConverges() throws {
        let moved = Chapter(start: 120, title: "Third")
        let chapters = [Chapter(start: 0, title: "First"), Chapter(start: 60, title: "Second"), moved]

        // Every keystroke of "0:30" that parses, in order, as the table commits them.
        for stamp in ["0:3", "0:30"] {
            let start = try XCTUnwrap(ChapterTableView.seconds(fromStamp: stamp, duration: 10_000))
            let edited = ChapterTableView.applying(start: start, toChapterWith: moved.id, in: chapters)
            try assertConverges(edited)
        }
    }

    /// The one that would otherwise churn. A trailing space typed into a title
    /// is trimmed by the parser, so storing it raw would come back as a
    /// different title, `preservingIdentity` would mint a fresh id, and the row
    /// the user is typing in would be destroyed and rebuilt. Normalizing on the
    /// way in is what prevents that.
    func testEditingATitleWithTrailingWhitespaceConverges() throws {
        let target = Chapter(start: 60, title: "Second")
        let chapters = [Chapter(start: 0, title: "First"), target]

        let normalized = ChapterTableView.applying(
            title: ChapterTableView.normalizedTitle("Interview "),
            toChapterWith: target.id,
            in: chapters
        )
        try assertConverges(normalized)
        XCTAssertEqual(normalized[1].id, target.id, "the row being typed in keeps its identity")

        // And the counter-example: storing the raw text does churn, which is
        // why `titleBinding` normalizes rather than passing the field through.
        let raw = ChapterTableView.applying(title: "Interview ", toChapterWith: target.id, in: chapters)
        let synced = try syncOnce(raw, duration: 10_000)
        XCTAssertNotEqual(synced.chapters, raw, "raw titles do not survive the round trip")
        XCTAssertNotEqual(synced.chapters[1].id, target.id, "which is exactly the identity churn to avoid")
    }

    func testEditingATitleWithANewlineConverges() throws {
        let target = Chapter(start: 60, title: "Second")
        let chapters = [Chapter(start: 0, title: "First"), target]
        let edited = ChapterTableView.applying(
            title: ChapterTableView.normalizedTitle("Two\nlines"),
            toChapterWith: target.id,
            in: chapters
        )
        try assertConverges(edited)
    }

    func testRemovingARowConverges() throws {
        let target = Chapter(start: 60, title: "Second")
        let chapters = [Chapter(start: 0, title: "First"), target, Chapter(start: 120, title: "Third")]
        try assertConverges(ChapterTableView.removing(id: target.id, from: chapters))
        try assertConverges([])
    }

    func testAddingARowConverges() throws {
        let chapters = [Chapter(start: 0, title: "First"), Chapter(start: 60, title: "Second")]
        let start = try XCTUnwrap(ChapterTableView.nextStart(after: chapters, duration: 10_000))
        let added = ChapterTableView.sorted(chapters + [Chapter(start: start, title: "New chapter")])
        try assertConverges(added)
        XCTAssertEqual(added.map(\.start), [0, 60, 120])
    }

    func testAnEmptyTableConverges() throws {
        let chapters: [Chapter] = []
        let start = try XCTUnwrap(ChapterTableView.nextStart(after: chapters, duration: 600))
        try assertConverges([Chapter(start: start, title: "New chapter")], duration: 600)
    }

    /// Every start the table can produce is a whole number of seconds, which is
    /// the other half of the fixpoint condition — `text(from:)` rounds, so a
    /// fractional start would come back as a different chapter.
    func testEveryStartTheTableProducesIsAWholeSecond() throws {
        for stamp in ["0:00", "1:30", "59:59", "1:00:00", "02:02:05"] {
            let start = try XCTUnwrap(ChapterTableView.seconds(fromStamp: stamp, duration: unbounded), stamp)
            XCTAssertEqual(start, start.rounded(), stamp)
        }
    }

    // MARK: - States the table can reach that do not parse

    /// Two rows sharing a start is reachable — retype one to match another —
    /// and the parser rejects it. The sheet must land in a visible error with
    /// both rows still on screen, not lose one or spin.
    func testDuplicateStartsSurfaceAnErrorWithoutLosingRows() {
        let target = Chapter(start: 120, title: "Third")
        let chapters = [Chapter(start: 0, title: "First"), Chapter(start: 60, title: "Second"), target]
        let clashing = ChapterTableView.applying(start: 60, toChapterWith: target.id, in: chapters)

        XCTAssertEqual(clashing.count, 3, "the row is still there for the user to fix")
        let text = MetadataSheet.text(from: clashing)
        XCTAssertEqual(
            ChapterParser.parse(text, duration: 10_000),
            .failure(.outOfOrder(number: 3))
        )
        // The failure leaves `draft.chapters` untouched, so nothing re-fires.
        XCTAssertEqual(MetadataSheet.text(from: clashing), text)
    }

    /// Clearing a title is reachable too, and must read as "add a title"
    /// rather than "this is not a chapter".
    func testClearingATitleSurfacesTheMissingTitleError() {
        let target = Chapter(start: 60, title: "Second")
        let chapters = [Chapter(start: 0, title: "First"), target]
        let blanked = ChapterTableView.applying(
            title: ChapterTableView.normalizedTitle("   "),
            toChapterWith: target.id,
            in: chapters
        )
        XCTAssertEqual(blanked.count, 2)
        guard case .failure(let error) = ChapterParser.parse(MetadataSheet.text(from: blanked), duration: 10_000) else {
            return XCTFail("an empty title must not parse")
        }
        XCTAssertEqual(error, .missingTitle(number: 2, text: "01:00"))
    }

    // MARK: - Why the paste box is not regenerated on every chapters change

    /// The sheet regenerates `chapterText` only from table writes. This is the
    /// reason: what a person types is rarely in canonical form, so an
    /// unconditional `onChange(of: draft.chapters)` would rewrite the box —
    /// and move the caret — while they are still typing in it.
    func testTypedTextIsNotItsOwnRegeneration() throws {
        let typed = "1:30 Intro"
        let parsed = try ChapterParser.parse(typed, duration: 10_000).get()
        XCTAssertEqual(MetadataSheet.text(from: parsed), "01:30 Intro")
        XCTAssertNotEqual(MetadataSheet.text(from: parsed), typed)
    }
}
