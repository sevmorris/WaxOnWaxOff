import XCTest
@testable import WaxOnWaxOff

final class FFmpegFiltersTests: XCTestCase {
    func testAresampleWithDitherIncludesTriangularHP() {
        let filter = FFmpegFilters.aresampleWithDither(to: 44100)
        XCTAssertTrue(filter.contains("dither_method=triangular_hp"))
        XCTAssertTrue(filter.contains("44100"))
    }
}
