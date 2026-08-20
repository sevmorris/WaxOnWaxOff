import SwiftUI

struct WaxOffControlBar: View {
    @Bindable var viewModel: DeliveryViewModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            knobCell(
                label: "TRUE PEAK",
                valueLabel: "\(viewModel.settings.truePeakString) dBTP",
                value: Binding(
                    get: { (viewModel.settings.truePeak - (-3.0)) / (-0.5 - (-3.0)) },
                    set: { viewModel.settings.truePeak = (($0 * (-0.5 - (-3.0)) + (-3.0)) * 2).rounded() / 2 }
                ),
                step: 1.0 / 5.0,
                help: "Maximum true peak for the WAV output. The MP3 pre-encode limiter automatically tracks 1 dB below this value to absorb the inter-sample peak overshoot lossy decoders introduce — set this to −1.0 and the decoded MP3 lands at or below −1.0 dBTP."
            )

            barDivider

            knobCell(
                label: "TARGET LUFS",
                valueLabel: "\(viewModel.settings.targetLUFSString) LUFS",
                value: Binding(
                    get: { (viewModel.settings.targetLUFS - (-24)) / (-14 - (-24)) },
                    set: { viewModel.settings.targetLUFS = ($0 * (-14 - (-24)) + (-24)).rounded() }
                ),
                step: 1.0 / 10.0,
                help: "Integrated loudness target for the delivery output. −18 LUFS is the typical podcast standard; lower values leave more headroom, higher values sound louder on platforms that do not normalize on playback."
            )

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.brandAccent.opacity(0.35))
                .frame(height: 1)
        }
    }

    private func knobCell(label: String, valueLabel: String, value: Binding<Double>, step: Double, help: String) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(AppFont.sectionLabel)
                .foregroundStyle(.secondary)
                .kerning(0.4)
            RotaryKnobView(
                value: value,
                size: 80,
                step: step,
                accessibilityLabel: label,
                accessibilityValueText: valueLabel
            )
            Text(valueLabel)
                .font(AppFont.valueMono)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .center)
        }
        .padding(.horizontal, 28)
        .frame(height: 170)
        .help(help)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 120)
    }
}
