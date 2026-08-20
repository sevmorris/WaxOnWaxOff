import SwiftUI

struct WaxOnControlBar: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            switchCell(
                line1: "HIGH", line2: "PASS",
                caption: "80 Hz — removes rumble & proximity",
                help: "80 Hz high-pass — removes rumble and proximity effect. DC offset is always removed regardless of this setting.",
                isOn: $viewModel.settings.highPassEnabled
            )

            barDivider

            switchCell(
                line1: "PHASE", line2: "ROTATION",
                caption: "200 Hz allpass — recovers headroom",
                help: "Allpass at 200 Hz — recovers headroom on asymmetric voice waveforms.",
                isOn: $viewModel.settings.phaseRotationEnabled
            )

            barDivider

            switchCell(
                line1: "DYNAMIC", line2: "LEVELING",
                caption: "Panels & live Q&As — may pump on solo voice with pauses",
                help: "Lifts quiet voices, tames loud ones — panel shows, live Q&As. Can cause pumping on solo voice with natural pauses.",
                isOn: $viewModel.settings.dynamicLevelingEnabled
            )

            knobCell(
                label: "STRENGTH",
                valueLabel: strengthLabel(viewModel.settings.dynamicLevelingAmount),
                caption: "",
                value: $viewModel.settings.dynamicLevelingAmount,
                step: 0.125,
                enabled: viewModel.settings.dynamicLevelingEnabled,
                help: "Max gain: Gentle +6 dB · Aggressive +15.6 dB. Audition output before editing."
            )

            barDivider

            switchCell(
                line1: "LOUDNESS", line2: "NORM",
                caption: "EBU R128 — consistent levels across files",
                help: "EBU R128 normalization to a target loudness — one measurement, one constant gain.",
                isOn: $viewModel.settings.loudnormEnabled
            )

            knobCell(
                label: "TARGET LUFS",
                valueLabel: String(format: "%.0f LUFS", viewModel.settings.loudnormTarget),
                caption: "Target loudness",
                value: Binding(
                    get: { (viewModel.settings.loudnormTarget - (-35)) / (-16 - (-35)) },
                    set: { viewModel.settings.loudnormTarget = ($0 * (-16 - (-35)) + (-35)).rounded() }
                ),
                step: 1.0 / 19.0,
                enabled: viewModel.settings.loudnormEnabled,
                help: "Loudness target in LUFS for EBU R128 normalization."
            )

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.brandAccent.opacity(0.35))
                .frame(height: 1)
        }
    }

    // MARK: - Cells

    private func switchCell(line1: String, line2: String, caption: String, help: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Spacer()

            twoLineLabel(line1: line1, line2: line2)
                .frame(height: 22)

            Spacer().frame(height: 22)

            ToggleSwitch(isOn: isOn, size: 18)

            Spacer().frame(height: 10)

            Text(caption)
                .font(AppFont.value)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(height: 48, alignment: .top)
        }
        .padding(.horizontal, 12)
        .frame(width: 150, height: 170)
        .help(help)
    }

    private func knobCell(label: String, valueLabel: String, caption: String, value: Binding<Double>, step: Double, enabled: Bool, help: String) -> some View {
        VStack(spacing: 0) {
            Spacer()

            Text(label)
                .font(AppFont.sectionLabel)
                .foregroundStyle(.secondary)
                .kerning(0.4)
                .frame(height: 22)

            Spacer().frame(height: 22)

            RotaryKnobView(
                value: value,
                size: 80,
                step: step,
                accessibilityLabel: label,
                accessibilityValueText: valueLabel
            )
            .disabled(!enabled)
            // Dim the knob itself, not just its label and value below. A
            // full-colour knob in a 150 pt slot reads as an active control
            // even when its toggle is off, which is most of the time for
            // Dynamic Leveling.
            .opacity(enabled ? 1 : 0.35)

            Spacer().frame(height: 6)

            Text(valueLabel)
                .font(AppFont.valueMono)
                .foregroundStyle(.secondary)
                .opacity(enabled ? 1 : 0.35)

            Spacer().frame(height: 4)

            Text(caption)
                .font(AppFont.value)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(height: 14, alignment: .top)
                .opacity(enabled ? 1 : 0.35)
        }
        .padding(.horizontal, 12)
        .frame(width: 150, height: 170)
        .help(help)
    }

    private func twoLineLabel(line1: String, line2: String) -> some View {
        VStack(spacing: 1) {
            Text(line1)
                .font(AppFont.sectionLabel)
                .foregroundStyle(.secondary)
                .kerning(0.4)
            Text(line2)
                .font(AppFont.sectionLabel)
                .foregroundStyle(.secondary)
                .kerning(0.4)
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 120)
    }

    private func strengthLabel(_ amount: Double) -> String {
        switch amount {
        case ..<0.25: return "Gentle"
        case ..<0.5:  return "Low"
        case ..<0.75: return "Medium"
        case ..<0.9:  return "High"
        default:      return "Aggressive"
        }
    }
}
