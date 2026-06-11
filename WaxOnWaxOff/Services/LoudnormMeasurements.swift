import Foundation
import OSLog

private let loudnormLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "LoudnormMeasurements")

/// Pass-1 measurements emitted by FFmpeg's `loudnorm=…:print_format=json`,
/// normalized to Doubles so callers don't re-parse them ad-hoc. Used by both
/// the WaxOn and WaxOff pipelines as the source of `measured_*` / `offset`
/// values plumbed into the pass-2 (linear) filter string.
struct LoudnormMeasurements: Sendable {
    var inputI: Double
    var inputTP: Double
    var inputLRA: Double
    var inputThresh: Double
    var targetOffset: Double

    nonisolated init?(json: [String: Any]) {
        guard let inputI = Self.parseNumber(json["input_i"]),
              let inputTP = Self.parseNumber(json["input_tp"]),
              let inputLRA = Self.parseNumber(json["input_lra"]),
              let inputThresh = Self.parseNumber(json["input_thresh"]),
              let targetOffset = Self.parseNumber(json["target_offset"])
        else { return nil }
        self.inputI = inputI
        self.inputTP = inputTP
        self.inputLRA = inputLRA
        self.inputThresh = inputThresh
        self.targetOffset = targetOffset
    }

    /// Silent or near-silent inputs cause `loudnorm` to emit `-inf` / `inf`
    /// for some measurements. Pass 2 rejects those values with "Result too
    /// large", so callers must check before plumbing measurements into the
    /// linear-mode filter string.
    nonisolated var isFinite: Bool {
        inputI.isFinite && inputTP.isFinite && inputLRA.isFinite &&
            inputThresh.isFinite && targetOffset.isFinite
    }

    /// `loudnorm=...:linear=true` args with this pass's measured values
    /// plumbed in. Caller supplies the target loudness, TP ceiling, and LRA
    /// (all three appear before the `measured_*` overrides in the chain).
    /// Values are clamped to loudnorm's documented option ranges before use;
    /// out-of-range measurements (e.g. input_i > 0 from a severely clipped
    /// source) cause an opaque FFmpeg error in pass 2 if passed unclamped.
    nonisolated func linearPassFilter(targetLUFS: Double, truePeakDB: Double, lra: Double) -> String {
        // Clamp to loudnorm's documented option ranges before injecting into pass 2.
        // measured_I: [−99, 0]  measured_TP: [−99, 99]
        // measured_LRA: [0, 99]  measured_thresh: [−99, 0]
        // target_offset (offset=) has no documented bound and is left unclamped.
        let measI      = max(-99, min(0,  inputI))
        let measTP     = max(-99, min(99, inputTP))
        let measLRA    = max(0,   min(99, inputLRA))
        let measThresh = max(-99, min(0,  inputThresh))
        if measI != inputI || measTP != inputTP || measLRA != inputLRA || measThresh != inputThresh {
            loudnormLogger.warning("Pass-1 measurements outside loudnorm option ranges — clamping before pass 2: I=\(self.inputI, privacy: .public)→\(measI, privacy: .public) TP=\(self.inputTP, privacy: .public)→\(measTP, privacy: .public) LRA=\(self.inputLRA, privacy: .public)→\(measLRA, privacy: .public) thresh=\(self.inputThresh, privacy: .public)→\(measThresh, privacy: .public)")
        }
        return "loudnorm=I=\(targetLUFS):TP=\(truePeakDB):LRA=\(lra)" +
            ":measured_I=\(measI):measured_TP=\(measTP)" +
            ":measured_LRA=\(measLRA):measured_thresh=\(measThresh)" +
            ":offset=\(targetOffset):linear=true"
    }

    /// "measured: -22.4 LUFS  |  TP -1.5 dBTP  |  LRA 5.0 LU" — one-line
    /// summary suitable for the user-facing processing log.
    nonisolated var formattedSummary: String {
        String(
            format: "measured: %.1f LUFS  |  TP %.1f dBTP  |  LRA %.1f LU",
            inputI, inputTP, inputLRA
        )
    }

    private nonisolated static func parseNumber(_ value: Any?) -> Double? {
        if let num = value as? Double { return num }
        if let str = value as? String { return Double(str) }
        return nil
    }
}
