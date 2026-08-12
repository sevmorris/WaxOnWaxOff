import SwiftUI

struct WaxOffMainView: View {
    @Environment(AppState.self) var appState
    var viewModel: DeliveryViewModel
    @State private var fileListWidth: CGFloat = 250
    @State private var showConsole = false
    @State private var showSettings = true
    @State private var metadataTarget: MetadataTarget?

    /// What the metadata sheet is editing, snapshotted when the button is
    /// pressed.
    ///
    /// `.sheet(item:)` over a snapshot rather than `.sheet(isPresented:)` over
    /// `selectedFile`, because the presented closure is re-evaluated whenever
    /// the view model changes. Reading the live selection in there gives two
    /// failure modes: a selection change behind the sheet would leave the
    /// already-seeded editor showing one file's values while Save wrote them to
    /// another, and a `selectedFile` that went nil (the row removed, the
    /// selection cleared) would render an empty sheet — with no Cancel button
    /// inside it, and no way to close it. A snapshot has neither: the sheet
    /// edits what it was opened on, and `updateMetadata` already no-ops if that
    /// row is gone by the time Save lands.
    ///
    /// It copies four fields rather than holding the `FileItem` itself, even
    /// though `FileItem` is already `Identifiable` and would bind to
    /// `.sheet(item:)` directly. Doing that would pin `waveform`,
    /// `outputWaveform`, `analysisStats`, `outputStats` and `outputFileInfo`
    /// alive for as long as the sheet is open, none of which the sheet reads.
    private struct MetadataTarget: Identifiable {
        let id: UUID
        let fileName: String
        let duration: TimeInterval?
        let metadata: EpisodeMetadata

        init(file: FileItem) {
            self.id = file.id
            self.fileName = file.url.lastPathComponent
            // The optional passes straight through. Coalescing to 0 would make
            // `ChapterParser`'s `start < duration` check reject every line the
            // user pastes into a file that is still analyzing.
            self.duration = file.fileInfo?.duration
            self.metadata = file.metadata
        }
    }

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
        // Same entry point as the drop above, published so the File menu can
        // reach it — the view models live here, not up in the Scene.
        .focusedSceneValue(\.addFiles, AddFilesAction(mode: .waxOff) { urls in
            viewModel.addFiles(urls)
        })
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
        // `.sheet(item:)` clears `metadataTarget` itself on dismiss, so both
        // Save and Cancel leave no presentation state behind.
        .sheet(item: $metadataTarget) { target in
            MetadataSheet(
                fileName: target.fileName,
                duration: target.duration,
                // Read live rather than snapshotted: the output mode is the one
                // input here that is not per-file, and the notice should be
                // right even if something changed it while the sheet is up.
                appliesToOutput: viewModel.settings.outputMode != .wav,
                metadata: target.metadata
            ) { updated in
                viewModel.updateMetadata(updated, for: target.id)
            }
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

            // Four states, and the view no longer works out which one it is in.
            // It used to walk isRestarting / isProcessing / isVerifying itself,
            // which meant the rule "Process is offered exactly when the model
            // would start a batch" lived in two places and was pinned in
            // neither. `toolbarState` decides; the tests assert the
            // correspondence.
            //
            // The reasons each state exists, since the enum cases cannot carry
            // them: isProcessing stays true until run() returns, which is after
            // the verification pool drains — keying Cancel/Process off it alone
            // left the toolbar claiming a delivery was still running for the
            // whole tail (#24). And a restart has isProcessing already false
            // while the previous batch is still unwinding, so without its own
            // state the toolbar showed an idle Process button and invited the
            // second press that `process()` now refuses.
            switch viewModel.toolbarState {
            case .restarting:
                // No control. The wait is subprocess teardown, it is short, and
                // there is nothing here worth cancelling.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting next batch…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .verifying:
                // Both controls, because both are meaningful here. Stop
                // verifying ends the advisory pass; Process starts the next
                // batch, cancelling that pass on its way. Cancel stays
                // available rather than hidden: drainVerifications honors
                // cancellation, so the button does something real — and what it
                // cancels costs nothing on disk, since every file is already
                // delivered. The label says so.
                //
                // Process stays disabled while newly dropped files analyze,
                // which is what makes "drop during the tail, then start" work
                // without any queueing machinery — the button simply lights up
                // when the new files are ready.
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

            case .delivering:
                Button {
                    viewModel.cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .tint(.red)

            case .idle:
                Button {
                    viewModel.process()
                } label: {
                    Label("Process", systemImage: "play.fill")
                }
                .disabled(viewModel.files.isEmpty || viewModel.isAnyFileAnalyzing)
                .help(viewModel.isAnyFileAnalyzing ? "Waiting for analysis to complete…" : "")
            }

            // Editing the list is refused while renders are in flight. The
            // batch works from a snapshot taken at Process, so removing rows
            // does not stop anything — the completion callbacks just stop
            // finding their rows, and files keep landing on disk with nothing
            // in the UI to show for them. Still allowed during the tail, where
            // the files are already written.
            Button {
                viewModel.removeSelected()
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .disabled(viewModel.selectedFileIDs.isEmpty || !viewModel.canEditFileList)

            Button {
                viewModel.clearAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(viewModel.files.isEmpty || !viewModel.canEditFileList)
            .keyboardShortcut(.delete, modifiers: [.command, .option])

            // Single selection only: every field the sheet edits is
            // per-episode, so there is no sensible batch meaning for it. Gated on
            // `canEditFileList` for the same reason Remove and Clear are — the
            // run works from a snapshot taken at Process, so an edit made
            // mid-batch would never reach the file being delivered.
            Button {
                guard let file = selectedFile else { return }
                metadataTarget = MetadataTarget(file: file)
            } label: {
                Label("Metadata", systemImage: "tag")
            }
            .disabled(viewModel.selectedFileIDs.count != 1 || !viewModel.canEditFileList)
            .help("Edit podcast metadata for the selected file")

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
            // The icon is the whole button, so the tooltip text is also the
            // only name this control has. A .help() is not exposed as a label.
            .accessibilityLabel(showSettings ? "Hide Settings" : "Show Settings")
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
                            // The full path, as WaxOn's identical header does.
                            .help(file.url.path)

                        if file.outputs.count > 1 {
                            OutputSwitcher(outputs: file.outputs, selectedIndex: file.selectedOutputIndex) {
                                viewModel.selectOutput(id: file.id, index: $0)
                            }
                        }

                        WaveformView(waveformData: file.selectedOutput?.waveform ?? file.waveform)
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
            .accessibilityLabel(showConsole ? "Show Waveform" : "Show Console")
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
                    phase: viewModel.filePhases[file.id],
                    showsMetadataBadge: true
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
