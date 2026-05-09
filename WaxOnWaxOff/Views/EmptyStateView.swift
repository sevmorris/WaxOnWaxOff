import SwiftUI

struct EmptyStateView: View {
    let mode: AppMode

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: mode == .waxOn ? "mic.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor.opacity(0.5))

            VStack(spacing: 8) {
                Text("Drag and drop audio files here to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("See Help menu for details on settings and processing.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    EmptyStateView(mode: .waxOn)
}
