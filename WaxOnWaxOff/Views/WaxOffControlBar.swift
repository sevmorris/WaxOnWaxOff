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
                step: 1.0 / 5.0
            )

            barDivider

            knobCell(
                label: "TARGET LUFS",
                valueLabel: "\(Int(viewModel.settings.targetLUFS)) LUFS",
                value: Binding(
                    get: { (viewModel.settings.targetLUFS - (-24)) / (-14 - (-24)) },
                    set: { viewModel.settings.targetLUFS = ($0 * (-14 - (-24)) + (-24)).rounded() }
                ),
                step: 1.0 / 10.0
            )

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(height: 1)
        }
    }

    private func knobCell(label: String, valueLabel: String, value: Binding<Double>, step: Double) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            RotaryKnobView(value: value, size: 80, step: step)
            Text(valueLabel)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .center)
        }
        .padding(.horizontal, 28)
        .frame(height: 170)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 120)
    }
}
