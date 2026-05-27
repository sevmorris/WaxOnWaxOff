import XCTest
@testable import WaxOnWaxOff

final class LoudnormMeasurementsTests: XCTestCase {

    func testInitParsesNumericAndStringValues() {
        let json: [String: Any] = [
            "input_i": "-23.5",
            "input_tp": -1.2,
            "input_lra": "5.0",
            "input_thresh": "-33.0",
            "target_offset": 4.5
        ]
        let measurements = LoudnormMeasurements(json: json)
        XCTAssertNotNil(measurements)
        XCTAssertEqual(measurements?.inputI, -23.5)
        XCTAssertEqual(measurements?.inputTP, -1.2)
    }

    func testIsFiniteRejectsNonFiniteValues() {
        let json: [String: Any] = [
            "input_i": "-inf",
            "input_tp": "-1.2",
            "input_lra": "5.0",
            "input_thresh": "-33.0",
            "target_offset": "4.5"
        ]
        var measurements = LoudnormMeasurements(json: json)!
        XCTAssertFalse(measurements.isFinite)

        measurements.inputI = -23.5
        XCTAssertTrue(measurements.isFinite)

        measurements.inputTP = .infinity
        XCTAssertFalse(measurements.isFinite)
    }
}
