import Foundation

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
    nonisolated func linearPassFilter(targetLUFS: Double, truePeakDB: Double, lra: Double) -> String {
        "loudnorm=I=\(targetLUFS):TP=\(truePeakDB):LRA=\(lra)" +
            ":measured_I=\(inputI):measured_TP=\(inputTP)" +
            ":measured_LRA=\(inputLRA):measured_thresh=\(inputThresh)" +
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
