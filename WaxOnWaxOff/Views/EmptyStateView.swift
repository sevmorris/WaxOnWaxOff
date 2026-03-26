import SwiftUI

struct EmptyStateView: View {
    let mode: AppMode

    var body: some View {
        VStack(spacing: 12) {
            Image(mode == .waxOn ? "WaxOnIcon" : "WaxOffIcon")
                .resizable()
                .frame(width: 160, height: 160)

            Text("Drag and drop audio files here to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("See Help menu for details on settings and processing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    EmptyStateView(mode: .waxOn)
}
