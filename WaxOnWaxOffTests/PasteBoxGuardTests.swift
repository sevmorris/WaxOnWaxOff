import XCTest
@testable import WaxOnWaxOff

/// The paste box must never be rewritten while it holds text the user is still
/// fixing. Rewriting it there discards what they typed, clears the error that
/// explained why Save was unavailable, and leaves the sheet looking as though
/// the edit had worked.
final class PasteBoxGuardTests: XCTestCase {

    func testRegeneratesWhenTheBoxParsesAndNoTimeFieldIsFocused() {
        XCTAssertTrue(MetadataSheet.mayRegeneratePasteBox(parseError: nil, isEditingChapterTime: false))
    }

    func testDoesNotRegenerateWhileTheBoxDoesNotParse() {
        XCTAssertFalse(
            MetadataSheet.mayRegeneratePasteBox(parseError: "Line 3 is not later than the chapter before it.",
                                                isEditingChapterTime: false),
            "rewriting here is the silent discard this guard exists to stop"
        )
    }

    func testDoesNotRegenerateWhileATimeFieldIsFocused() {
        XCTAssertFalse(MetadataSheet.mayRegeneratePasteBox(parseError: nil, isEditingChapterTime: true))
    }

    func testDoesNotRegenerateWhenBothConditionsHold() {
        XCTAssertFalse(MetadataSheet.mayRegeneratePasteBox(parseError: "bad", isEditingChapterTime: true))
    }

    /// The reported case: one line retyped past the next line's time. The list
    /// becomes unparsable, so the edit never commits — and the text must
    /// survive for the user to correct.
    func testTheReportedEditIsNotOverwritten() {
        let lastGood = [
            Chapter(start: 1778, title: "Approaching private data"),
            Chapter(start: 1838, title: "Twinkl, a love letter to the web"),
            Chapter(start: 1898, title: "Eskahlay"),
        ]
        let typed = """
        29:38 Approaching private data
        39:45 Twinkl, a love letter to the web
        31:38 Eskahlay
        """
        guard case .failure(let error) = ChapterParser.parse(typed, duration: 3427.9) else {
            return XCTFail("expected the out-of-order rejection")
        }
        // With an error showing, the sheet must not rewrite the box.
        XCTAssertFalse(
            MetadataSheet.mayRegeneratePasteBox(parseError: error.errorDescription,
                                                isEditingChapterTime: false)
        )
        // What the old behaviour would have put there instead.
        XCTAssertTrue(MetadataSheet.text(from: lastGood).contains("30:38"),
                      "the old time is what the discard restored")
    }
}
