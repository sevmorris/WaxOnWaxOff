import Foundation
import OSLog

/// Hidden-flag performance instrumentation.
///
/// Off by default; enable with:
///
///     defaults write io.github.sevmorris.WaxOnWaxOff WaxPerfLog -bool YES
///
/// When enabled, per-stage wall times for every FFmpeg invocation and for the
/// Swift-side analysis/waveform passes are emitted to the unified log:
///
///     log stream --predicate 'subsystem == "io.github.sevmorris.WaxOnWaxOff" AND category == "Perf"'
///
/// When disabled, the only per-stage cost is one UserDefaults boolean read —
/// labels are built lazily via @autoclosure and never touch the app's
/// processing console, so user-visible log output is unchanged either way.
nonisolated enum PerfLog {
    private static let logger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "Perf")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WaxPerfLog")
    }

    /// Elapsed seconds since `start`.
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// One line per completed stage: wall seconds + label. Emitted at the
    /// default (notice) level, not .info — info-level messages are memory-only
    /// under the default log configuration and invisible to a post-hoc
    /// `log show`, which defeats the point of audit instrumentation.
    static func record(_ label: @autoclosure () -> String, seconds: Double) {
        guard isEnabled else { return }
        let text = label()
        logger.log("⏱ \(String(format: "%8.3f", seconds), privacy: .public)s  \(text, privacy: .public)")
    }

    /// Compact label for an FFmpeg invocation: executable, input, output, filter prefix.
    static func ffmpegLabel(exe: String, args: [String]) -> String {
        let input = args.firstIndex(of: "-i").map { args[$0 + 1] } ?? "?"
        let output = args.last ?? "?"
        let af = args.firstIndex(of: "-af").map { String(args[$0 + 1].prefix(48)) } ?? "-"
        return "\((exe as NSString).lastPathComponent) in=\((input as NSString).lastPathComponent) "
            + "out=\((output as NSString).lastPathComponent) af=\(af)"
    }
}
