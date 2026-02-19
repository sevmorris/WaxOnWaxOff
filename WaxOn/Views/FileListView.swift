import SwiftUI
import AppKit

struct FileListView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        List(selection: $viewModel.selectedFileIDs) {
            ForEach(viewModel.files) { file in
                FileRowView(file: file)
                    .tag(file.id)
            }
            .onDelete { offsets in
                viewModel.removeFiles(at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveFiles(from: source, to: destination)
            }
        }
    }
}

struct FileRowView: View {
    let file: FileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(file.url.lastPathComponent)
                    .font(.body)

                if case .processing = file.status {
                    ProgressView()
                        .controlSize(.small)
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
