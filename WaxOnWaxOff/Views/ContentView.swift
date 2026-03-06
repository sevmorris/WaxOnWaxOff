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
        }
        .frame(minWidth: 900, minHeight: 540)
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
            EmptyStateView()
        } else {
            FileListView(viewModel: viewModel)
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    FileInfoStatsView(file: file)
                }
                .padding()
            } else if let phase = viewModel.mixPhase {
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
            .background {
                if let url = Bundle.main.url(forResource: "WaxOn_bg", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: nsImage.size.width * 0.1875,
                               height: nsImage.size.height * 0.1875)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomTrailing)
                        .padding(.bottom, 10)
                        .padding(.trailing, 24)
                        .padding([.top, .leading], 12)
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
