import SwiftUI
import AppKit

/// A short pre-process channel-conversion hint shown next to the filename
/// (e.g. "MONO→STEREO" in WaxOff, "STEREO→MONO L" in WaxOn).
struct ChannelBadge: Equatable {
    let label: String
    let help: String
}

struct FileListView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        List(selection: $viewModel.selectedFileIDs) {
            ForEach(viewModel.files) { file in
                FileRowView(
                    file: file,
                    isProcessing: viewModel.isProcessing,
                    channelBadge: channelBadge(for: file)
                )
                    .tag(file.id)
            }
            .onDelete { offsets in
                viewModel.removeFiles(at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveFiles(from: source, to: destination)
            }
        }
        .background(
            Button("") {
                guard !viewModel.selectedFileIDs.isEmpty else { return }
                viewModel.removeSelected()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .hidden()
        )
    }

    /// In WaxOn we surface the inverse of WaxOff's MONO→STEREO badge: when the
    /// source has more than one channel and the user has Mono output selected,
    /// some channels are about to be discarded. The badge is a heads-up so a
    /// stereo room recording isn't silently turned into a single-channel grab.
    private func channelBadge(for file: FileItem) -> ChannelBadge? {
        guard viewModel.settings.outputChannels == .mono,
              let info = file.fileInfo,
              info.channelCount > 1 else { return nil }

        if info.channelCount == 2 {
            let isLeft = viewModel.settings.channel == .left
            let tag = isLeft ? "L" : "R"
            let word = isLeft ? "left" : "right"
            return ChannelBadge(
                label: "STEREO→MONO \(tag)",
                help: "Stereo source — only the \(word) channel will be kept in the mono output. Switch Output to Stereo in Settings to keep both channels."
            )
        }
        return ChannelBadge(
            label: "MULTI→MONO",
            help: "\(info.channelCount)-channel source — will be downmixed to mono via FFmpeg's default matrix (center and surrounds summed in)."
        )
    }
}

struct FileRowView: View {
    let file: FileItem
    var isProcessing: Bool = false
    var channelBadge: ChannelBadge? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(file.url.lastPathComponent)
                    .font(.body)

                if let badge = channelBadge, !file.isProcessed {
                    Text(badge.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help(badge.help)
                }

                if file.hasHighNoiseFloor {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("High noise floor — loudness normalization may be less accurate. Enable Loudness Norm so the automatic NR analysis runs.")
                }

                if file.isProcessed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Complete")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if let outputURL = file.outputURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
            }

            statusText

            if case .processing = file.status {
                ProgressView(value: nil as Double?)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else if isProcessing, case .ready = file.status {
                ProgressView(value: 0.0, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .opacity(0.35)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch file.status {
        case .pending:
            Text("Waiting...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .analyzing:
            Text("Calculating stats...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .processing:
            Text("Processing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready(let stats):
            Text("RMS \(stats.rms, specifier: "%.1f") dBFS \u{2022} Peak \(stats.peak, specifier: "%.1f") dBFS")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .processed(let outputURL):
            Text("Output: \(outputURL.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let message):
            Text("Error: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
