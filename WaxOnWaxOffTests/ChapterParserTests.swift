import XCTest
@testable import WaxOnWaxOff

final class ChapterParserTests: XCTestCase {

    // MARK: - Happy paths

    func testParsesMinuteSecondForm() throws {
        let text = """
        00:00 Cold Open
        01:30 Main Interview
        """
        let chapters = try ChapterParser.parse(text, duration: 600).get()
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].start, 0)
        XCTAssertEqual(chapters[0].title, "Cold Open")
        XCTAssertEqual(chapters[1].start, 90)
        XCTAssertEqual(chapters[1].title, "Main Interview")
    }

    func testParsesHourMinuteSecondForm() throws {
        let chapters = try ChapterParser.parse("01:02:03 Late Chapter", duration: 7200).get()
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].start, 3723)
    }

    func testMinutesMayExceed59InTwoPartForm() throws {
        let chapters = try ChapterParser.parse("90:00 Ninety Minutes In", duration: 7200).get()
        XCTAssertEqual(chapters[0].start, 5400)
    }

    func testSkipsBlankLines() throws {
        let text = """

        00:00 First

        02:00 Second

        """
        let chapters = try ChapterParser.parse(text, duration: 600).get()
        XCTAssertEqual(chapters.count, 2)
    }

    func testTitleMayContainSpacesColonsAndPunctuation() throws {
        let chapters = try ChapterParser.parse("00:00 Part 1: What's Next?", duration: 600).get()
        XCTAssertEqual(chapters[0].title, "Part 1: What's Next?")
    }

    func testTabSeparatorIsAccepted() throws {
        let chapters = try ChapterParser.parse("00:00\tTabbed Title", duration: 600).get()
        XCTAssertEqual(chapters[0].title, "Tabbed Title")
    }

    func testEmptyInputProducesNoChapters() throws {
        let chapters = try ChapterParser.parse("   \n\n  ", duration: 600).get()
        XCTAssertTrue(chapters.isEmpty)
    }

    // MARK: - Errors

    func testMalformedLineReportsItsLineNumber() {
        let text = """
        00:00 Fine
        not a timestamp
        """
        guard case .failure(let error) = ChapterParser.parse(text, duration: 600) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .malformedLine(number: 2, text: "not a timestamp"))
    }

    func testSecondsAbove59AreRejected() {
        guard case .failure(let error) = ChapterParser.parse("00:75 Bad", duration: 600) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .malformedLine(number: 1, text: "00:75 Bad"))
    }

    func testMissingTitleIsRejected() {
        guard case .failure(let error) = ChapterParser.parse("00:00", duration: 600) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .missingTitle(number: 1, text: "00:00"))
    }

    func testOutOfOrderTimestampsAreRejected() {
        let text = """
        05:00 Later
        01:00 Earlier
        """
        guard case .failure(let error) = ChapterParser.parse(text, duration: 600) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .outOfOrder(number: 2))
    }

    func testDuplicateTimestampsAreRejected() {
        let text = """
        01:00 One
        01:00 Two
        """
        guard case .failure(let error) = ChapterParser.parse(text, duration: 600) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .outOfOrder(number: 2))
    }

    func testTimestampBeyondDurationIsRejected() {
        guard case .failure(let error) = ChapterParser.parse("10:00 Too Late", duration: 300) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .beyondDuration(number: 1, start: 600, duration: 300))
    }

    func testTimestampExactlyAtDurationIsRejected() {
        guard case .failure = ChapterParser.parse("05:00 At The End", duration: 300) else {
            return XCTFail("Expected failure")
        }
    }

    // MARK: - Notes (non-fatal)

    func testFirstChapterAfterZeroIsAllowed() throws {
        let chapters = try ChapterParser.parse("00:30 Starts Late", duration: 600).get()
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].start, 30)
    }

    // MARK: - Line endings

    func testWindowsLineEndingsParseCorrectly() throws {
        let chapters = try ChapterParser.parse("00:00 First\r\n01:00 Second", duration: 600).get()
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[1].start, 60)
        XCTAssertEqual(chapters[1].title, "Second")
    }

    func testWindowsLineEndingsDoNotShiftReportedLineNumbers() {
        let text = "00:00 First\r\n01:00 Second\r\nnot a timestamp"
        guard case .failure(let error) = ChapterParser.parse(text, duration: 600) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .malformedLine(number: 3, text: "not a timestamp"),
                       "CRLF input must not shift the reported line number")
    }

    func testClassicMacLineEndingsParseCorrectly() throws {
        let chapters = try ChapterParser.parse("00:00 First\r01:00 Second", duration: 600).get()
        XCTAssertEqual(chapters.count, 2)
    }

    // MARK: - Additional validation

    func testMinutesAbove59AreRejectedInThreePartForm() {
        guard case .failure(let error) = ChapterParser.parse("00:75:00 Bad Minutes", duration: 7200) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .malformedLine(number: 1, text: "00:75:00 Bad Minutes"))
    }

    func testBareNumberWithoutColonIsRejected() {
        guard case .failure(let error) = ChapterParser.parse("90 Intro", duration: 7200) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .malformedLine(number: 1, text: "90 Intro"))
    }

    /// Regression for an Int-overflow trap. `Int("9999999999999999")` parses
    /// cleanly and only blows up when multiplied by 3600, and Swift's `*` traps
    /// rather than wrapping — so before the bound check in `seconds(from:)`
    /// this input aborted the process instead of returning an error. The
    /// parser re-runs on every keystroke in the chapter text box, so a trap
    /// here would take the app down mid-typing.
    func testOverflowingHourComponentIsRejectedNotCrashed() {
        guard case .failure = ChapterParser.parse("9999999999999999:00:00 Overflow", duration: 600) else {
            return XCTFail("Expected failure, not a crash")
        }
    }

    /// The two-part form multiplies by 60 rather than 3600, so it needs a
    /// larger value to overflow — but it overflows just the same, and the same
    /// bound check is what prevents it.
    func testOverflowingMinuteComponentIsRejectedNotCrashed() {
        guard case .failure = ChapterParser.parse("999999999999999999:00 Overflow", duration: 600) else {
            return XCTFail("Expected failure, not a crash")
        }
    }

    func testZeroDurationRejectsEveryLine() {
        guard case .failure(let error) = ChapterParser.parse("00:00 Anything", duration: 0) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .beyondDuration(number: 1, start: 0, duration: 0))
    }
}
