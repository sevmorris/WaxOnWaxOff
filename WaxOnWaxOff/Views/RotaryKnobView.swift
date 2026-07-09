import SwiftUI

struct RotaryKnobView: View {
    @Binding var value: Double   // 0…1
    var size: CGFloat = 52
    var step: Double = 0.05
    /// VoiceOver / accessibility label (e.g. "Target LUFS").
    var accessibilityLabel: String = "Control"
    /// Spoken value (e.g. "-18 LUFS").
    var accessibilityValueText: String = ""

    private static let minAngle: Double = -135
    private static let maxAngle: Double =  135
    private var rotation: Angle {
        .degrees(Self.minAngle + value * (Self.maxAngle - Self.minAngle))
    }

    @State private var dragStart: (value: Double, y: CGFloat)?

    var body: some View {
        ZStack {
            tickRing
            knobFace
        }
        .frame(width: size, height: size)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStart == nil {
                        dragStart = (value, drag.startLocation.y)
                    }
                    guard let start = dragStart else { return }
                    let pixelsPerStep: CGFloat = 8
                    let steps = (start.y - drag.location.y) / pixelsPerStep
                    let raw = start.value + Double(steps) * step
                    value = max(0, min(1, (raw / step).rounded() * step))
                }
                .onEnded { _ in dragStart = nil }
        )
        .scrollWheelStep { delta in
            adjustValue(direction: delta > 0 ? 1 : -1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValueText.isEmpty ? formattedValue : accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustValue(direction: 1)
            case .decrement: adjustValue(direction: -1)
            @unknown default: break
            }
        }
        .accessibilityAddTraits(.isButton)
        .focusable()
        // Keep the knob keyboard-focusable (arrow-key nudging below) but suppress the
        // system's rectangular focus ring, which looks wrong around a circular control.
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            adjustValue(direction: 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            adjustValue(direction: -1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            adjustValue(direction: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            adjustValue(direction: 1)
            return .handled
        }
        .help("\(accessibilityLabel): drag vertically, scroll wheel, or arrow keys to adjust.")
        .cursor(.resizeUpDown)
    }

    private var formattedValue: String {
        String(format: "%.0f%%", value * 100)
    }

    private func adjustValue(direction: Double) {
        value = max(0, min(1, ((value + direction * step) / step).rounded() * step))
    }

    // MARK: - Subviews

    private var knobFace: some View {
        Image("KnobFace")
            .resizable()
            .scaledToFill()
            .clipShape(Circle())
            .frame(width: size * 0.72, height: size * 0.72)
            .rotationEffect(rotation)
            .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
    }

    private var tickRing: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerR = size.width / 2 - 1
            let innerR = outerR - 5
            let totalTicks = 11
            let sweep = Self.maxAngle - Self.minAngle

            for i in 0..<totalTicks {
                let fraction = Double(i) / Double(totalTicks - 1)
                let angleDeg = Self.minAngle + fraction * sweep
                let rad = angleDeg * .pi / 180
                let cosA = CGFloat(Foundation.cos(rad - .pi / 2))
                let sinA = CGFloat(Foundation.sin(rad - .pi / 2))

                let outer = CGPoint(x: center.x + outerR * cosA, y: center.y + outerR * sinA)
                let inner = CGPoint(x: center.x + innerR * cosA, y: center.y + innerR * sinA)

                var path = Path()
                path.move(to: outer)
                path.addLine(to: inner)

                ctx.stroke(
                    path,
                    with: .color(fraction <= value ? Color.brandAccent : Color.primary.opacity(0.2)),
                    lineWidth: i == 0 || i == totalTicks - 1 ? 2 : 1.5
                )
            }

            let startRad = (Self.minAngle - 90) * .pi / 180
            let endRad   = (Self.maxAngle - 90) * .pi / 180
            var arc = Path()
            arc.addArc(center: center, radius: outerR,
                       startAngle: .radians(startRad), endAngle: .radians(endRad),
                       clockwise: false)
            ctx.stroke(arc, with: .color(Color.primary.opacity(0.1)), lineWidth: 1)
        }
    }
}

// MARK: - Scroll wheel

extension View {
    func scrollWheelStep(perform action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollWheelHost(onScroll: action))
    }

    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in inside ? cursor.push() : NSCursor.pop() }
    }
}

private struct ScrollWheelHost: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(onScroll: onScroll) }
    func updateNSView(_ v: Tracker, context: Context) { v.onScroll = onScroll }

    class Tracker: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
        // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
        // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
        // tearing down its task-local scope when AppKit releases this backing view
        // off-task as knobs appear and disappear. Nothing in teardown needs the
        // actor, so opt out.
        nonisolated deinit {}

        override func scrollWheel(with event: NSEvent) {
            guard abs(event.deltaY) > 0 else { return }
            onScroll(event.deltaY)
        }
    }
}

// MARK: - Helpers

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

#Preview {
    @Previewable @State var val = 0.5
    VStack(spacing: 20) {
        RotaryKnobView(value: $val, size: 64)
        Text(String(format: "%.2f", val)).monospacedDigit()
    }
    .padding(40)
}
