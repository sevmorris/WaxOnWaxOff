import SwiftUI

struct EmptyStateView: View {
    let mode: AppMode

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: mode == .waxOn ? "mic.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(Color.brandAccent.opacity(0.5))

            VStack(spacing: 8) {
                // Simplified Technical English, as the Help text and the manual
                // are: one instruction to a sentence, active voice, approved
                // vocabulary. The drop was the only way in until the bar below
                // this view gained its Add button, so both are named.
                Text("Drag your audio files onto this window. As an alternative, click the plus button below the list.")
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
