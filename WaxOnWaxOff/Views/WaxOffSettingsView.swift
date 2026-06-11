import SwiftUI
import AppKit

struct WaxOffSettingsView: View {
    @Bindable var viewModel: DeliveryViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OUTPUT FORMAT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .kerning(0.4)
                    .padding(.top, 6)
                    .padding(.horizontal, 2)

                row(nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledToggleSwitch(
                            selection: $viewModel.settings.sampleRate,
                            leftLabel: "44.1 kHz",
                            leftValue: 44100,
                            rightLabel: "48 kHz",
                            rightValue: 48000
                        )
                        .frame(maxWidth: .infinity)
                        if viewModel.settings.outputMode != .wav {
                            Text("MP3 always outputs at 44.1 kHz")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(viewModel.settings.outputMode == .mp3)
                .opacity(viewModel.settings.outputMode == .mp3 ? 0.4 : 1)
                .help(viewModel.settings.outputMode == .mp3 ? "MP3 always outputs at 44.1 kHz" : "")

                row(nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $viewModel.settings.outputMode) {
                            Text("WAV").tag(OutputMode.wav)
                            Text("MP3").tag(OutputMode.mp3)
                            Text("Both").tag(OutputMode.both)
                        }
                        .pickerStyle(.segmented)
                        Text("Stereo only — mono files are not accepted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

                VStack(alignment: .leading, spacing: 5) {
                    Text("OUTPUT DIR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
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
    private func row<Content: View>(_ label: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(0.4)
            }
            content()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
