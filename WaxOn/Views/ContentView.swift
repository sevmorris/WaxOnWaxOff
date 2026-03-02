import SwiftUI

struct ContentView: View {
    @State private var viewModel = ContentViewModel()
    @State private var fileListWidth: CGFloat = 250

    private var selectedFile: FileItem? {
        guard viewModel.selectedFileIDs.count == 1,
              let id = viewModel.selectedFileIDs.first,
              let file = viewModel.files.first(where: { $0.id == id })
        else { return nil }
        return file
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            HStack(spacing: 0) {
                fileListSection
                    .frame(width: fileListWidth)

                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 4)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = fileListWidth + value.translation.width
                                fileListWidth = max(150, min(newWidth, 600))
                            }
                    )

                waveformSection
                    .frame(minWidth: 300)
            }
            SettingsView(viewModel: viewModel)
        }
        .frame(minWidth: 900, minHeight: 620)
        .padding(.bottom)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFiles(urls)
            return !urls.isEmpty
        }
        .alert("Error", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    private var headerView: some View {
        HStack {
            Text("WaxOn").font(.title2).bold()
            Spacer()

            if viewModel.isProcessing {
                Button {
                    viewModel.cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .tint(.red)
            } else {
                Button {
                    viewModel.process()
                } label: {
                    Label("Process", systemImage: "play.fill")
                }
                .disabled(viewModel.files.isEmpty)
            }

            Button {
                viewModel.mixSelected()
            } label: {
                Label("Mix", systemImage: "waveform.badge.plus")
            }
            .disabled(viewModel.selectedFileIDs.count < 2 || viewModel.isProcessing)

            Button {
                viewModel.removeSelected()
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .disabled(viewModel.selectedFileIDs.isEmpty)

            Button {
                viewModel.clearAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
        }
        .padding()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var fileListSection: some View {
        if viewModel.files.isEmpty {
            EmptyStateView()
        } else {
            FileListView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var waveformSection: some View {
        if let file = selectedFile {
            VStack(alignment: .leading, spacing: 8) {
                Text(file.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                WaveformView(waveformData: file.waveform)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        } else {
            VStack {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Select a file to view waveform")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )
    }
}

#Preview {
    ContentView()
}
