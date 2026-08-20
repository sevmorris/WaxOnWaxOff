import SwiftUI

/// Picks which of a completed row's outputs the detail pane shows. Only
/// appears when a job wrote more than one file — WaxOn's Split L/R, or
/// WaxOff's Both format.
struct OutputSwitcher: View {
    let outputs: [OutputFile]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(outputs.enumerated()), id: \.element.id) { index, output in
                Button {
                    onSelect(index)
                } label: {
                    Text(output.label)
                        .font(AppFont.sectionLabel)
                        .foregroundStyle(index == selectedIndex ? Color.brandAccent : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(index == selectedIndex ? Color.brandAccent.opacity(0.15) : Color.secondary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(output.url.lastPathComponent)
            }
        }
        .accessibilityLabel("Output file")
    }
}
