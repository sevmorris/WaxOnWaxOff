import SwiftUI

/// Pill-style toggle switch. When `tinted` is true the track glows accent-orange when on;
/// when false the track stays neutral and only the thumb position conveys state.
struct ToggleSwitch: View {
    @Binding var isOn: Bool
    var size: CGFloat = 22
    var tinted: Bool = true

    private var trackWidth: CGFloat { size * 1.85 }
    private var thumbSize: CGFloat { size - 4 }
    private var thumbOffset: CGFloat { (trackWidth - thumbSize) / 2 - 2 }

    var body: some View {
        ZStack {
            Capsule()
                .fill(trackFill)
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(
                    color: tinted && isOn ? Color.accentColor.opacity(0.6) : .clear,
                    radius: tinted && isOn ? 4 : 0
                )

            Circle()
                .fill(Color.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
                .offset(x: isOn ? thumbOffset : -thumbOffset)
        }
        .frame(width: trackWidth, height: size)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                isOn.toggle()
            }
        }
    }

    private var trackFill: AnyShapeStyle {
        if tinted && isOn {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(Color.primary.opacity(0.18))
    }
}

/// Two-value selector: left label, switch, right label. Click any of the three.
struct LabeledToggleSwitch<Value: Equatable>: View {
    @Binding var selection: Value
    let leftLabel: String
    let leftValue: Value
    let rightLabel: String
    let rightValue: Value
    var labelWidth: CGFloat = 56
    var switchSize: CGFloat = 16

    private var isRight: Bool { selection == rightValue }

    var body: some View {
        HStack(spacing: 8) {
            Text(leftLabel)
                .font(.system(size: 11, weight: isRight ? .regular : .semibold))
                .foregroundStyle(isRight ? .secondary : .primary)
                .frame(width: labelWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        selection = leftValue
                    }
                }

            ToggleSwitch(
                isOn: Binding(
                    get: { isRight },
                    set: { selection = $0 ? rightValue : leftValue }
                ),
                size: switchSize,
                tinted: false
            )

            Text(rightLabel)
                .font(.system(size: 11, weight: isRight ? .semibold : .regular))
                .foregroundStyle(isRight ? .primary : .secondary)
                .frame(width: labelWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        selection = rightValue
                    }
                }
        }
    }
}

#Preview {
    @Previewable @State var on = false
    @Previewable @State var rate = 44100

    VStack(spacing: 24) {
        ToggleSwitch(isOn: $on)
        LabeledToggleSwitch(
            selection: $rate,
            leftLabel: "44.1 kHz",
            leftValue: 44100,
            rightLabel: "48 kHz",
            rightValue: 48000
        )
    }
    .padding(40)
}
