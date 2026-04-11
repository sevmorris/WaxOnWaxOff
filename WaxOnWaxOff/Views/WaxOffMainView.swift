import SwiftUI

struct WaxOffMainView: View {
    @Environment(AppState.self) var appState
    var viewModel: DeliveryViewModel
    @State private var fileListWidth: CGFloat = 250
    @State private var showConsole = false
    @State private var showSettings = true

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
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
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

                if showSettings {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1)
                        WaxOffSettingsView(viewModel: viewModel)
                            .frame(width: 260)
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .frame(minWidth: 1092, minHeight: 624)
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
            ModeSwitcher()

            Divider()
                .frame(height: 20)

            WaxOffPresetPicker(viewModel: viewModel)

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

            Divider()
                .frame(height: 20)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help(showSettings ? "Hide Settings" : "Show Settings")
        }
        .padding()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var fileListSection: some View {
        if viewModel.files.isEmpty {
            EmptyStateView(mode: .waxOff)
        } else {
            DeliveryFileListView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var waveformSection: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if showConsole {
                    ConsoleView(log: viewModel.log)
                        .padding([.top, .leading, .trailing])
                        .padding(.bottom, 72)
                } else if let file = selectedFile {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        WaveformView(waveformData: file.waveform)
                            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                            .background(.black.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        FileInfoStatsView(file: file)
                    }
                    .padding()
                } else if let phase = viewModel.deliveryPhase {
                    VStack(spacing: 10) {
                        ProgressView().scaleEffect(1.2)
                        Text(phase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Button {
                showConsole.toggle()
            } label: {
                Image(systemName: showConsole ? "waveform" : "terminal")
                    .font(.callout)
                    .padding(9)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(showConsole ? "Show Waveform" : "Show Console")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )
    }
}

// MARK: - DeliveryFileListView

private struct DeliveryFileListView: View {
    @Bindable var viewModel: DeliveryViewModel

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
        .onDeleteCommand {
            guard !viewModel.selectedFileIDs.isEmpty else { return }
            viewModel.removeSelected()
        }
    }
}
