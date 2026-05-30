import Foundation

/// Shared FFmpeg `filter` fragments for WaxOn/WaxOff processing chains.
enum FFmpegFilters {

    /// Resample to `rate` Hz. Uses SWResample with a large filter — the bundled static
    /// FFmpeg build does not include the SoXR engine (`resampler=soxr` fails at runtime).
    nonisolated static func aresample(to rate: Int) -> String {
        "aresample=\(rate):filter_size=512:cutoff=0.97:phase_shift=10"
    }

    /// Escape a value for FFmpeg `-metadata key=value` arguments.
    nonisolated static func metadataValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "=", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Format an `alimiter=limit=N` value: linear amplitude derived from a dBFS
    /// ceiling, rendered to 6 decimal places so the string we pass to FFmpeg is
    /// stable across builds and matches the rounded value documented in
    /// theory.html (e.g. -1.0 dBTP → 0.891251).
    nonisolated static func limiterCeilingAmplitude(dBFS: Double) -> String {
        String(format: "%.6f", pow(10.0, dBFS / 20.0))
    }
}
