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

    func testLinearPassFilterClampsOutOfRangeValues() {
        // inputI=+5 (range [−99,0]), inputTP=+120 (range [−99,99]),
        // inputLRA=−3 (range [0,99]), inputThresh=+2 (range [−99,0]).
        let json: [String: Any] = [
            "input_i":       5.0,
            "input_tp":    120.0,
            "input_lra":    -3.0,
            "input_thresh":  2.0,
            "target_offset": 0.0
        ]
        let m = LoudnormMeasurements(json: json)!
        let filter = m.linearPassFilter(targetLUFS: -16, truePeakDB: -1, lra: 11)
        XCTAssertTrue(filter.contains("measured_I=0.0"),     filter)
        XCTAssertTrue(filter.contains("measured_TP=99.0"),   filter)
        XCTAssertTrue(filter.contains("measured_LRA=0.0"),   filter)
        XCTAssertTrue(filter.contains("measured_thresh=0.0"), filter)
    }

    func testLinearPassFilterPreservesInRangeValues() {
        let json: [String: Any] = [
            "input_i":      -23.5,
            "input_tp":      -1.2,
            "input_lra":      5.0,
            "input_thresh": -33.0,
            "target_offset":  4.5
        ]
        let m = LoudnormMeasurements(json: json)!
        let filter = m.linearPassFilter(targetLUFS: -16, truePeakDB: -1, lra: 11)
        XCTAssertTrue(filter.contains("measured_I=-23.5"),     filter)
        XCTAssertTrue(filter.contains("measured_TP=-1.2"),     filter)
        XCTAssertTrue(filter.contains("measured_LRA=5.0"),     filter)
        XCTAssertTrue(filter.contains("measured_thresh=-33.0"), filter)
    }
}
