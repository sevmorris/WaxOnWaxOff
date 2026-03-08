import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row("Sample Rate") {
                    Picker("", selection: $viewModel.settings.sampleRate) {
                        Text("44.1 kHz").tag(WaxOnSettings.SampleRate.s44100)
                        Text("48 kHz").tag(WaxOnSettings.SampleRate.s48000)
                    }
                    .pickerStyle(.segmented)
                }

                row("Output") {
                    Picker("", selection: $viewModel.settings.outputChannels) {
                        Text("Mono").tag(WaxOnSettings.OutputChannels.mono)
                        Text("Stereo").tag(WaxOnSettings.OutputChannels.stereo)
                    }
                    .pickerStyle(.segmented)
                }

                row("Channel") {
                    Picker("", selection: $viewModel.settings.channel) {
                        Text("Left").tag(WaxOnSettings.MonoChannel.left)
                        Text("Right").tag(WaxOnSettings.MonoChannel.right)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(viewModel.settings.outputChannels == .stereo)
                .opacity(viewModel.settings.outputChannels == .stereo ? 0.4 : 1)

                Divider().padding(.vertical, 6)

                row("Ceiling") {
                    HStack(spacing: 6) {
                        Slider(value: $viewModel.settings.limitDb, in: -3 ... -1, step: 1)
                        Text(String(format: "%.0f dB", viewModel.settings.limitDb))
                            .font(.system(size: 11).monospaced())
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                row("High Pass") {
                    HStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.settings.dcBlockHz) },
                                set: { viewModel.settings.dcBlockHz = Int($0) }
                            ),
                            in: 20...90,
                            step: 5
                        )
                        Text(viewModel.settings.dcBlockHz == 20 ? "DC Block" : "\(viewModel.settings.dcBlockHz) Hz")
                            .font(.system(size: 11).monospaced())
                            .frame(width: 55, alignment: .trailing)
                    }
                }

                Divider().padding(.vertical, 6)

                row("Noise Reduction") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $viewModel.settings.noiseReductionEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Text("RNNoise (ML)")
                        }
                        Text("Check output before editing — artifacts are possible on heavy noise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                row("Loudness Norm") {
                    Toggle("", isOn: $viewModel.settings.loudnormEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                row("Target") {
                    HStack(spacing: 6) {
                        Slider(value: $viewModel.settings.loudnormTarget, in: -35 ... -16, step: 1)
                        Text(String(format: "%.0f LUFS", viewModel.settings.loudnormTarget))
                            .font(.system(size: 11).monospaced())
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!viewModel.settings.loudnormEnabled)
                .opacity(!viewModel.settings.loudnormEnabled ? 0.4 : 1)

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
