import Foundation

/// Shared FFmpeg `filter` fragments for WaxOn/WaxOff processing chains.
enum FFmpegFilters {

    /// Resample to `rate` Hz. Uses SWResample with a large filter — the bundled static
    /// FFmpeg build does not include the SoXR engine (`resampler=soxr` fails at runtime).
    /// Used for both intermediate hops and final-export resamples. No dither is applied:
    /// all outputs are 24-bit PCM, which involves no word-length reduction and therefore
    /// requires no dithering.
    nonisolated static func aresample(to rate: Int) -> String {
        "aresample=\(rate):filter_size=512:cutoff=0.97:phase_shift=10"
    }

    /// Sanitize a value passed to FFmpeg as `-metadata key=value`. We pass
    /// metadata via `Process.arguments` (no shell), so the only characters we
    /// actually need to defuse are `=` (would re-split the pair) and embedded
    /// newlines (corrupt single-line tag formats like MP3 ID3). Backslashes
    /// are preserved — substituting them with `/` would silently rewrite
    /// titles like "Episode 12\3" to "Episode 12/3".
    nonisolated static func metadataValue(_ value: String) -> String {
        value
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
