import Foundation
import OSLog

nonisolated private let loudnormLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "LoudnormMeasurements")

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

    /// Why `linear=true` was refused, when it is refused.
    enum DynamicFallbackReason {
        /// Measured loudness range exceeds the configured LRA target.
        case loudnessRange(measured: Double, target: Double)
        /// A single constant gain would push true peak past the TP ceiling.
        case truePeak(projected: Double, ceiling: Double)
        /// A `measured_*` value collided with loudnorm's "not supplied" sentinel,
        /// so the filter ignores the whole measured set and never tries linear mode.
        case measurementsNotRecognised
    }

    /// Predicts whether FFmpeg will honour `linear=true` in pass 2, or silently
    /// fall back to dynamic normalization. Returns nil when linear mode is
    /// predicted; otherwise the reason it is not.
    ///
    /// This mirrors `af_loudnorm.c` init() at FFmpeg 8.0 exactly, and models
    /// **both** of its gates, not only the documented inequality:
    ///
    ///   1. the sentinel guard — linear mode is considered only when every
    ///      `measured_*` differs from its option default (`measured_tp != 99`,
    ///      `measured_thresh != -70`, `measured_lra != 0`, `measured_i != 0`),
    ///      which is how the filter detects that a measured set was supplied
    ///      at all;
    ///   2. the predicate — `(measured_tp + (target_i - measured_i)) <= target_tp
    ///      && measured_lra <= target_lra`.
    ///
    /// Modelling only (2) disagrees with FFmpeg on quiet material, where a real
    /// measured threshold of exactly −70 or a measured LRA of exactly 0 trips a
    /// sentinel and forces dynamic mode regardless of the inequality.
    ///
    /// The offset is recomputed locally, as FFmpeg does — it does **not** read
    /// the `offset=` value this type forwards. FFmpeg overwrites its own
    /// `s->offset` with this local value if and only if linear mode is chosen.
    ///
    /// Evaluated against the same clamped values `linearPassFilter` injects,
    /// since those are what the filter actually receives.
    nonisolated func predictsLinearMode(
        targetLUFS: Double,
        truePeakDB: Double,
        lra: Double
    ) -> DynamicFallbackReason? {
        let (measI, measTP, measLRA, measThresh) = clampedForPass2()

        guard measTP != 99, measThresh != -70, measLRA != 0, measI != 0 else {
            return .measurementsNotRecognised
        }
        if measLRA > lra {
            return .loudnessRange(measured: measLRA, target: lra)
        }
        let offsetTP = measTP + (targetLUFS - measI)
        if offsetTP > truePeakDB {
            return .truePeak(projected: offsetTP, ceiling: truePeakDB)
        }
        return nil
    }

    /// User-facing console line for a predicted fallback, or nil when linear
    /// mode is predicted. Shared so WaxOn and WaxOff word it identically.
    nonisolated func dynamicFallbackWarning(
        targetLUFS: Double,
        truePeakDB: Double,
        lra: Double
    ) -> String? {
        guard let reason = predictsLinearMode(targetLUFS: targetLUFS, truePeakDB: truePeakDB, lra: lra) else {
            return nil
        }
        switch reason {
        case let .loudnessRange(measured, target):
            return String(format: "⚠ Loudness range %.1f LU exceeds the %.0f LU target — loudnorm will apply dynamic normalization, not a single constant gain. Expect a result under target with reduced loudness range.",
                          measured, target)
        case let .truePeak(projected, ceiling):
            return String(format: "⚠ A constant gain would reach %.1f dBTP, past the %.1f dBTP ceiling — loudnorm will apply dynamic normalization instead. Expect a result under target with reduced loudness range.",
                          projected, ceiling)
        case .measurementsNotRecognised:
            return "⚠ Pass-1 measurements collide with loudnorm's not-supplied defaults — loudnorm will apply dynamic normalization, not a single constant gain."
        }
    }

    /// The `measured_*` set as pass 2 receives it, clamped to loudnorm's
    /// documented option ranges. Shared so the prediction and the filter string
    /// can never disagree about what the filter was told.
    private nonisolated func clampedForPass2() -> (i: Double, tp: Double, lra: Double, thresh: Double) {
        (max(-99, min(0,  inputI)),
         max(-99, min(99, inputTP)),
         max(0,   min(99, inputLRA)),
         max(-99, min(0,  inputThresh)))
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
        let (measI, measTP, measLRA, measThresh) = clampedForPass2()
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
