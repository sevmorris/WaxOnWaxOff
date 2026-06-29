import SwiftUI

/// Semantic color tokens. Routes the brand accent and the metering warning/critical
/// colors through named values so the palette can be tuned in one place later.
/// Each token is defined to exactly equal the literal color its call sites rendered
/// before the indirection was introduced — adopting them changes no rendered color.
extension Color {
    /// Brand accent used across controls, highlights, and the waveform gradient.
    static let brandAccent = Color.accentColor

    /// Metering caution: peak ≥ −3 dBFS, noise floor > −50 dBFS, high-noise-floor badge.
    static let meterWarning = Color.orange

    /// Metering danger: peak ≥ 0 dBFS, noise floor > −40 dBFS.
    static let meterCritical = Color.red
}
