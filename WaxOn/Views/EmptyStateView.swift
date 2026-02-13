import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Welcome to WaxOn")
                    .font(.title2)
                    .bold()

                Text("WaxOn prepares podcast recordings for editing in a DAW. It applies high-pass filtering, loudness normalization, phase rotation, and brick-wall limiting, outputting clean 24-bit WAV files ready for import.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 500)
            }

            VStack(spacing: 4) {
                Text("To get started:")
                    .font(.headline)
                    .padding(.top, 8)

                Label("Drag and drop audio files here", systemImage: "arrow.down.doc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    EmptyStateView()
}
