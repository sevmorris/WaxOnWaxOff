import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    var viewModel: ContentViewModel
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

                if showSettings {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1)
                        SettingsView(viewModel: viewModel)
                            .frame(width: 260)
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
                }
            }
            WaxOnControlBar(viewModel: viewModel)
        }
        .frame(minWidth: 1092, minHeight: 624)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFiles(urls)
            return !urls.isEmpty
        }
        .alert("Error", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .alert("Already Processed?", isPresented: Binding(
            get: { viewModel.showWaxonWarning },
            set: { if !$0 { viewModel.dismissWaxonWarning() } }
        )) {
            Button("Add Anyway") { viewModel.confirmWaxonWarning() }
            Button("Cancel", role: .cancel) { viewModel.dismissWaxonWarning() }
        } message: {
            Text("One or more files appear to have already been processed by WaxOn. Processing them again may degrade audio quality.")
        }
    }

    private var headerView: some View {
        HStack {
            ModeSwitcher()

            Divider()
                .frame(height: 20)

            WaxOnPresetPicker(viewModel: viewModel)

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
                .disabled(viewModel.files.isEmpty || viewModel.isAnyFileAnalyzing)
                .help(viewModel.isAnyFileAnalyzing ? "Waiting for analysis to complete…" : "")
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
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var fileListSection: some View {
        if viewModel.files.isEmpty {
            EmptyStateView(mode: appState.mode ?? .waxOn)
        } else {
            VStack(spacing: 0) {
                // Show a non-blocking note when phase rotation is on and multiple files
                // are queued. If they were recorded simultaneously in the same room,
                // independent phase rotation per track can cause cancellation when mixed.
                // Dismisses automatically when the condition is no longer met.
                if viewModel.settings.phaseRotationEnabled && viewModel.files.count > 1 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.top, 1)
                        Text("Phase rotation is on. If these files were recorded simultaneously in the same room, disabling it will prevent phase cancellation when the tracks are combined.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.07))
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 1)
                }
                FileListView(viewModel: viewModel)
            }
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
                        .help(file.url.path)

                    WaveformView(waveformData: file.outputWaveform ?? file.waveform)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    FileInfoStatsView(file: file)
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

#Preview {
    ContentView(viewModel: ContentViewModel())
        .environment(AppState())
}
