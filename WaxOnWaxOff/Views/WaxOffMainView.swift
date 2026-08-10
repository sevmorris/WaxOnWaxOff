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
            WaxOffControlBar(viewModel: viewModel)
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
        .alert("Already Delivered?", isPresented: Binding(
            get: { viewModel.showWaxoffWarning },
            set: { if !$0 { viewModel.dismissWaxoffWarning() } }
        )) {
            Button("Add Anyway") { viewModel.confirmWaxoffWarning() }
            Button("Cancel", role: .cancel) { viewModel.dismissWaxoffWarning() }
        } message: {
            Text("One or more files appear to have already been processed by WaxOff. Running delivery again may over-limit or drift from your target loudness.")
        }
    }

    private var headerView: some View {
        HStack {
            ModeSwitcher()

            Divider()
                .frame(height: 20)

            WaxOffPresetPicker(viewModel: viewModel)

            Spacer()

            // Batch-level, and here rather than in the waveform pane on purpose.
            // Verification runs after every row has already said Complete, so it
            // belongs to the batch, not to a row; and the pane's fallback chain
            // only renders when nothing is selected, so a readout placed there
            // disappears the moment the user clicks a finished row. Sitting next
            // to Cancel also puts it beside the control you would reach for if it
            // looked stuck — which is the complaint that prompted #23.
            if let completed = viewModel.verificationsCompleted {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying delivered files… \(completed) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Three states, not two. `isProcessing` stays true until run()
            // returns, which is after the verification pool drains — so keying
            // Cancel/Process off it alone left the toolbar claiming a delivery
            // was still running for the whole tail (#24). `isVerifying` splits
            // that window: files are written, only the advisory re-measurement
            // remains.
            //
            // Cancel stays available during the tail rather than being hidden.
            // drainVerifications honours cancellation, so the button still does
            // something real — and what it cancels costs nothing on disk, since
            // every file is already delivered. The label says so.
            if viewModel.isProcessing && viewModel.isVerifying {
                // Both controls, because both are meaningful here. Stop
                // verifying ends the advisory pass; Process starts the next
                // batch, cancelling that pass on its way. Process stays
                // disabled while newly dropped files analyse, which is what
                // makes "drop during the tail, then start" work without any
                // queueing machinery — the button simply lights up when the
                // new files are ready.
                Button {
                    viewModel.cancelProcessing()
                } label: {
                    Label("Stop verifying", systemImage: "stop.fill")
                }
                .help("Files are delivered. This stops the remaining verification passes only.")

                Button {
                    viewModel.process()
                } label: {
                    Label("Process", systemImage: "play.fill")
                }
                .disabled(viewModel.files.isEmpty || viewModel.isAnyFileAnalyzing)
                .help(viewModel.isAnyFileAnalyzing
                      ? "Waiting for analysis to complete…"
                      : "Starts the next batch and stops the remaining verification passes.")
            } else if viewModel.isProcessing {
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
                .fill(Color.brandAccent.opacity(0.35))
                .frame(height: 1)
        }
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

                        WaveformView(waveformData: file.outputWaveform ?? file.waveform)
                            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                            .background(.black.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        FileInfoStatsView(file: file, applyFloorWarnings: false)
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

// MARK: - DeliveryFileListView

private struct DeliveryFileListView: View {
    @Bindable var viewModel: DeliveryViewModel

    var body: some View {
        List(selection: $viewModel.selectedFileIDs) {
            ForEach(viewModel.files) { file in
                FileRowView(
                    file: file,
                    isProcessing: viewModel.isProcessing,
                    channelBadge: Self.upmixBadge(for: file),
                    applyFloorWarnings: false,
                    phase: viewModel.filePhases[file.id]
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
        .onDeleteCommand {
            guard !viewModel.selectedFileIDs.isEmpty else { return }
            viewModel.removeSelected()
        }
    }

    private static func upmixBadge(for file: FileItem) -> ChannelBadge? {
        guard file.fileInfo?.channelCount == 1 else { return nil }
        return ChannelBadge(
            label: "MONO",
            help: "Mono input — upmixed to dual-mono stereo before processing, unless Mono delivery is on"
        )
    }
}
