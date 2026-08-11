import XCTest
@testable import WaxOnWaxOff

final class ChapterMetadataFileTests: XCTestCase {

    func testHeaderIsFirstLine() {
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: 0, title: "One")],
            duration: 60
        )
        XCTAssertTrue(text.hasPrefix(";FFMETADATA1\n"))
    }

    func testChapterEndsWhereNextBegins() {
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: 0, title: "One"), Chapter(start: 30, title: "Two")],
            duration: 60
        )
        XCTAssertTrue(text.contains("START=0\nEND=30000\ntitle=One"))
    }

    func testLastChapterEndsAtDuration() {
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: 0, title: "One"), Chapter(start: 30, title: "Two")],
            duration: 60
        )
        XCTAssertTrue(text.contains("START=30000\nEND=60000\ntitle=Two"))
    }

    func testTimebaseIsMilliseconds() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: "One")], duration: 60)
        XCTAssertTrue(text.contains("TIMEBASE=1/1000"))
    }

    func testFractionalStartsAreRoundedToMilliseconds() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 1.2345, title: "One")], duration: 60)
        XCTAssertTrue(text.contains("START=1235"), "Expected 1.2345 s to round to 1235 ms, got:\n\(text)")
    }

    func testEmptyChapterListProducesHeaderOnly() {
        let text = ChapterMetadataFile.contents(for: [], duration: 60)
        XCTAssertEqual(text, ";FFMETADATA1\n")
    }

    // MARK: - Escaping

    func testEqualsInTitleIsEscaped() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: "A=B")], duration: 60)
        XCTAssertTrue(text.contains(#"title=A\=B"#))
    }

    func testSemicolonAndHashAreEscaped() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: "A;B#C")], duration: 60)
        XCTAssertTrue(text.contains(##"title=A\;B\#C"##))
    }

    func testBackslashIsEscapedFirst() {
        // A lone backslash must become two, and must not double-escape the
        // characters escaped afterwards.
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: #"A\B"#)], duration: 60)
        XCTAssertTrue(text.contains(#"title=A\\B"#))
    }

    func testBackslashBeforeEqualsIsNotDoubleEscaped() {
        // "A\=B" must become "A\\\=B": the backslash doubles, then the equals
        // gets its own escape — not "A\\=B" (equals unescaped) and not
        // "A\\\\=B" (backslash escaped twice).
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: #"A\=B"#)], duration: 60)
        XCTAssertTrue(text.contains(#"title=A\\\=B"#), "got:\n\(text)")
    }

    func testNewlineInTitleIsEscaped() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: "A\nB")], duration: 60)
        XCTAssertFalse(text.contains("title=A\nB"), "A raw newline would end the value early")
        XCTAssertTrue(text.contains("title=A\\\nB"))
    }

    // MARK: - Defensive bounds (this function is not guaranteed a pre-validated Chapter)

    func testHugeStartDoesNotTrap() {
        // Int(Double) traps if the value doesn't fit. Nothing upstream of this
        // function is contractually required to bound `start`, so a caller
        // passing a huge value must saturate, not crash the app mid-delivery.
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: .greatestFiniteMagnitude, title: "One")],
            duration: 60
        )
        XCTAssertTrue(text.contains("START=\(Int.max)"))
    }

    func testNonFiniteStartDoesNotTrap() {
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: .infinity, title: "One"), Chapter(start: .nan, title: "Two")],
            duration: 60
        )
        XCTAssertTrue(text.contains("START=\(Int.max)"))
        XCTAssertTrue(text.contains("START=0"))
    }

    func testNegativeStartClampsToZero() {
        // Chapter starts are never legitimately negative; clamping rather
        // than propagating a negative millisecond value keeps the file valid.
        let text = ChapterMetadataFile.contents(for: [Chapter(start: -5, title: "One")], duration: 60)
        XCTAssertTrue(text.contains("START=0"))
    }

    // MARK: - Precondition violations (documented, not defended)

    func testSingleChapterEndsAtDuration() {
        // The single-chapter path through the END ternary is exercised by
        // several tests but its END value is asserted by none of them.
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: "Only")], duration: 90)
        XCTAssertTrue(text.contains("START=0\nEND=90000\ntitle=Only"), "got:\n\(text)")
    }

    func testOutOfOrderChaptersProduceEndBeforeStart() {
        // Pins current behaviour rather than endorsing it: the precondition
        // says callers must sort. If a future change adds sorting, this test
        // should fail and be rewritten deliberately, not silently deleted.
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: 30, title: "Later"), Chapter(start: 10, title: "Earlier")],
            duration: 60
        )
        XCTAssertTrue(text.contains("START=30000\nEND=10000"), "got:\n\(text)")
    }

    func testDuplicateStartsProduceZeroLengthChapter() {
        let text = ChapterMetadataFile.contents(
            for: [Chapter(start: 10, title: "A"), Chapter(start: 10, title: "B")],
            duration: 60
        )
        XCTAssertTrue(text.contains("START=10000\nEND=10000"), "got:\n\(text)")
    }

    func testChapterStartingAfterDurationProducesEndBeforeStart() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 120, title: "Past End")], duration: 60)
        XCTAssertTrue(text.contains("START=120000\nEND=60000"), "got:\n\(text)")
    }

    func testEmptyTitleStillProducesAWellFormedLine() {
        let text = ChapterMetadataFile.contents(for: [Chapter(start: 0, title: "")], duration: 60)
        XCTAssertTrue(text.contains("\ntitle=\n") || text.hasSuffix("\ntitle=\n"), "got:\n\(text)")
    }

    // MARK: - Writing

    func testWriteProducesAReadableFile() throws {
        let url = try ChapterMetadataFile.write(
            chapters: [Chapter(start: 0, title: "One")],
            duration: 60,
            directory: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix(";FFMETADATA1"))
    }

    func testWriteReturnsUniquePathsForRepeatedCalls() throws {
        let a = try ChapterMetadataFile.write(chapters: [Chapter(start: 0, title: "One")],
                                              duration: 60,
                                              directory: FileManager.default.temporaryDirectory)
        let b = try ChapterMetadataFile.write(chapters: [Chapter(start: 0, title: "One")],
                                              duration: 60,
                                              directory: FileManager.default.temporaryDirectory)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(a, b, "Concurrent deliveries must not share a chapters file path")
    }
}
