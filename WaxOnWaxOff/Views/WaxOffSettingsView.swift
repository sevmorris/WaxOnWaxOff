import SwiftUI
import AppKit

struct WaxOffSettingsView: View {
    @Bindable var viewModel: DeliveryViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row("Sample Rate") {
                    Picker("", selection: $viewModel.settings.sampleRate) {
                        Text("44.1 kHz").tag(44100)
                        Text("48 kHz").tag(48000)
                    }
                    .pickerStyle(.segmented)
                }

                row("Output") {
                    Picker("", selection: $viewModel.settings.outputMode) {
                        Text("WAV").tag(OutputMode.wav)
                        Text("MP3").tag(OutputMode.mp3)
                        Text("Both").tag(OutputMode.both)
                    }
                    .pickerStyle(.segmented)
                }

                row("MP3 Bitrate") {
                    Picker("", selection: $viewModel.settings.mp3Bitrate) {
                        Text("128 kbps").tag(128)
                        Text("160 kbps").tag(160)
                        Text("192 kbps").tag(192)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(viewModel.settings.outputMode == .wav)
                .opacity(viewModel.settings.outputMode == .wav ? 0.4 : 1)

                Divider().padding(.vertical, 6)

                row("True Peak") {
                    HStack(spacing: 6) {
                        Slider(value: $viewModel.settings.truePeak, in: -3.0 ... -0.1, step: 0.1)
                        Text("\(viewModel.settings.truePeakString) dBTP")
                            .font(.system(size: 11).monospaced())
                            .frame(width: 76, alignment: .trailing)
                    }
                }

                row("Target LUFS") {
                    HStack(spacing: 6) {
                        Slider(value: $viewModel.settings.targetLUFS, in: -24 ... -14, step: 1)
                        Text(viewModel.settings.targetLUFS == viewModel.settings.targetLUFS.rounded()
                             ? "\(Int(viewModel.settings.targetLUFS)) LUFS"
                             : String(format: "%.1f LUFS", viewModel.settings.targetLUFS))
                            .font(.system(size: 11).monospaced())
                            .frame(width: 60, alignment: .trailing)
                    }
                }

                Divider().padding(.vertical, 6)

                row("Phase Rotation") {
                    Toggle("150 Hz allpass", isOn: $viewModel.settings.phaseRotationEnabled)
                        .toggleStyle(.switch)
                }

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text("OUTPUT DIR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .kerning(0.4)
                    if let path = viewModel.settings.outputDirectoryPath {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Same as source")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                viewModel.settings.outputDirectoryPath = url.path
                            }
                        }
                        .controlSize(.small)
                        if viewModel.settings.outputDirectoryPath != nil {
                            Button("Reset") {
                                viewModel.settings.outputDirectoryPath = nil
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .padding(12)
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            content()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
