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

    // MARK: - predictsLinearMode
    //
    // Mirrors af_loudnorm.c init() at FFmpeg 8.0. Both gates are covered: the
    // sentinel guard that detects whether a measured set was supplied at all,
    // and the two-term predicate. Values chosen so each case trips exactly one.

    private func measurements(
        i: Double = -22.0, tp: Double = -3.0, lra: Double = 5.0, thresh: Double = -33.0
    ) -> LoudnormMeasurements {
        let m = LoudnormMeasurements(json: [
            "input_i": i, "input_tp": tp, "input_lra": lra,
            "input_thresh": thresh, "target_offset": 4.0
        ])
        return m!
    }

    /// Both conditions satisfied: range inside target, and the constant gain
    /// keeps true peak under the ceiling. −3 + (−18 − −22) = +1 … which is
    /// above −1, so use a quieter source to stay under.
    func testPredictsLinearWhenBothConditionsHold() {
        let m = measurements(i: -22.0, tp: -8.0, lra: 5.0)
        // offsetTP = -8 + (-18 - -22) = -4.0 <= -1.0, and 5.0 <= 9.0
        XCTAssertNil(m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9))
    }

    /// Loudness range above target forces dynamic mode. This is the WaxOff
    /// default case the audit measured: input LRA 18.3 against LRA=9.
    func testPredictsDynamicWhenLoudnessRangeExceedsTarget() {
        let m = measurements(i: -22.0, tp: -8.0, lra: 18.3)
        guard case .loudnessRange(let measured, let target)? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("expected a loudnessRange fallback")
        }
        XCTAssertEqual(measured, 18.3)
        XCTAssertEqual(target, 9)
    }

    /// True-peak headroom forces dynamic mode even when the range is fine.
    /// offsetTP = -1 + (-18 - -22) = +3.0, past the -1.0 ceiling.
    func testPredictsDynamicWhenConstantGainWouldBreachCeiling() {
        let m = measurements(i: -22.0, tp: -1.0, lra: 2.0)
        guard case .truePeak(let projected, let ceiling)? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("expected a truePeak fallback")
        }
        XCTAssertEqual(projected, 3.0, accuracy: 0.0001)
        XCTAssertEqual(ceiling, -1)
    }

    /// Sentinel: measured_thresh of exactly -70 is loudnorm's "not supplied"
    /// default. It is also a legitimate measurement for very quiet material, so
    /// FFmpeg ignores the whole measured set and never attempts linear mode —
    /// even though both predicate terms would otherwise pass.
    func testSentinelThresholdMinus70ForcesDynamic() {
        let m = measurements(i: -22.0, tp: -8.0, lra: 2.0, thresh: -70.0)
        guard case .measurementsNotRecognised? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("measured_thresh == -70 must trip the sentinel guard")
        }
    }

    /// Sentinel: measured_lra of exactly 0 — digital silence, or a perfectly
    /// flat source — is loudnorm's default and likewise disables linear mode.
    func testSentinelLoudnessRangeZeroForcesDynamic() {
        let m = measurements(i: -22.0, tp: -8.0, lra: 0.0)
        guard case .measurementsNotRecognised? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("measured_lra == 0 must trip the sentinel guard")
        }
    }

    /// Sentinel: measured_i of exactly 0 LUFS.
    func testSentinelIntegratedZeroForcesDynamic() {
        let m = measurements(i: 0.0, tp: -8.0, lra: 2.0)
        guard case .measurementsNotRecognised? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("measured_i == 0 must trip the sentinel guard")
        }
    }

    /// Sentinel: measured_tp of exactly 99. Reachable only through the clamp,
    /// but the guard must model it because FFmpeg does.
    func testSentinelTruePeak99ForcesDynamic() {
        let m = measurements(i: -22.0, tp: 99.0, lra: 2.0)
        guard case .measurementsNotRecognised? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("measured_tp == 99 must trip the sentinel guard")
        }
    }

    /// The prediction is evaluated against the same clamped values the filter
    /// string carries, so the two can never disagree about what FFmpeg was told.
    /// An unclamped input_i of +3 clamps to 0, which is the sentinel.
    func testPredictionUsesTheClampedValuesTheFilterSends() {
        let m = measurements(i: 3.0, tp: -8.0, lra: 2.0)
        XCTAssertTrue(m.linearPassFilter(targetLUFS: -18, truePeakDB: -1, lra: 9).contains("measured_I=0.0"))
        guard case .measurementsNotRecognised? =
                m.predictsLinearMode(targetLUFS: -18, truePeakDB: -1, lra: 9) else {
            return XCTFail("clamped measured_i of 0 must trip the sentinel guard")
        }
    }

    /// The warning names which condition failed, and is nil when linear holds.
    func testWarningTextTracksTheReason() {
        XCTAssertNil(measurements(i: -22.0, tp: -8.0, lra: 5.0)
            .dynamicFallbackWarning(targetLUFS: -18, truePeakDB: -1, lra: 9))

        let range = measurements(i: -22.0, tp: -8.0, lra: 18.3)
            .dynamicFallbackWarning(targetLUFS: -18, truePeakDB: -1, lra: 9)
        XCTAssertTrue(range?.contains("Loudness range") == true, range ?? "nil")

        let peak = measurements(i: -22.0, tp: -1.0, lra: 2.0)
            .dynamicFallbackWarning(targetLUFS: -18, truePeakDB: -1, lra: 9)
        XCTAssertTrue(peak?.contains("dBTP ceiling") == true, peak ?? "nil")
    }
}
