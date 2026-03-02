import SwiftUI

struct ModePicker: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("WaxOn/WaxOff")
                    .font(.largeTitle.bold())
                Text("Podcast Audio Prep for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                ModeCard(
                    title: "WaxOn",
                    subtitle: "Prepare raw recordings for editing",
                    systemImage: "waveform.badge.mic"
                ) {
                    appState.mode = .waxOn
                }

                ModeCard(
                    title: "WaxOff",
                    subtitle: "Finalize and deliver your mix",
                    systemImage: "arrow.up.circle"
                ) {
                    appState.mode = .waxOff
                }
            }
        }
        .padding(32)
        .frame(width: 560, height: 320)
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(.title2.bold())

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isHovering ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.12),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    ModePicker()
        .environment(AppState())
}
