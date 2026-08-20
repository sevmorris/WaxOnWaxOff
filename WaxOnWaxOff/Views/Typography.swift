import SwiftUI

/// The panel type scale, in one place.
///
/// These sizes lived as magic numbers duplicated across the two settings
/// panels, the two control bars, the stats strip and the file list — which is
/// how they drifted apart and why they were hard to adjust. Change them here.
///
/// The panels are a fixed 260 pt wide inside a vertical ScrollView, so a larger
/// size costs extra wrapping, never clipping.
enum AppFont {
    /// ALL-CAPS section and control labels: OUTPUT FORMAT, CHANNELS, HIGH PASS.
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    /// Values and inline control text.
    static let value = Font.system(size: 13)
    /// Monospaced readouts, so digits do not shift as values change.
    static let valueMono = Font.system(size: 13).monospaced()
    /// Numeric readouts in the stats strip.
    static let statValue = Font.system(size: 14, weight: .medium).monospaced()
    /// Explanatory text under a control.
    static let help = Font.system(size: 12)
}
