import XCTest
@testable import WaxOnWaxOff

final class ChapterRangeTests: XCTestCase {

    func testKeepsChaptersInsideDuration() {
        let kept = DeliveryProcessor.chaptersWithinDuration(
            [Chapter(start: 0, title: "A"), Chapter(start: 30, title: "B")],
            duration: 60
        )
        XCTAssertEqual(kept.count, 2)
    }

    func testDropsChaptersPastTheEnd() {
        let kept = DeliveryProcessor.chaptersWithinDuration(
            [Chapter(start: 0, title: "A"), Chapter(start: 90, title: "B")],
            duration: 60
        )
        XCTAssertEqual(kept.map(\.title), ["A"])
    }

    func testDropsChapterExactlyAtDuration() {
        // A chapter starting exactly at the end has zero length and would make
        // FFmpeg write START == END.
        let kept = DeliveryProcessor.chaptersWithinDuration(
            [Chapter(start: 60, title: "At end")],
            duration: 60
        )
        XCTAssertTrue(kept.isEmpty)
    }

    func testPreservesOrder() {
        let kept = DeliveryProcessor.chaptersWithinDuration(
            [Chapter(start: 0, title: "A"), Chapter(start: 10, title: "B"), Chapter(start: 20, title: "C")],
            duration: 60
        )
        XCTAssertEqual(kept.map(\.title), ["A", "B", "C"])
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertTrue(DeliveryProcessor.chaptersWithinDuration([], duration: 60).isEmpty)
    }
}
