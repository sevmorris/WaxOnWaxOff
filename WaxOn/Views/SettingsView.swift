import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Sample Rate")
                    Picker("", selection: $viewModel.settings.sampleRate) {
                        Text("44.1 kHz").tag(WaxOnSettings.SampleRate.s44100)
                        Text("48 kHz").tag(WaxOnSettings.SampleRate.s48000)
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("Output")
                    Picker("", selection: $viewModel.settings.outputChannels) {
                        Text("Mono").tag(WaxOnSettings.OutputChannels.mono)
                        Text("Stereo").tag(WaxOnSettings.OutputChannels.stereo)
                    }
                    .pickerStyle(.segmented)
                }

                if viewModel.settings.outputChannels == .mono {
                    GridRow {
                        Text("Channel")
                        Picker("", selection: $viewModel.settings.channel) {
                            Text("Left").tag(WaxOnSettings.MonoChannel.left)
                            Text("Right").tag(WaxOnSettings.MonoChannel.right)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                GridRow {
                    Text("Ceiling")
                    HStack {
                        Slider(value: $viewModel.settings.limitDb, in: -3 ... -1, step: 1)
                        Text(String(format: "%.0f dB", viewModel.settings.limitDb))
                            .frame(width: 80, alignment: .trailing)
                    }
                }

                GridRow {
                    Text("High Pass")
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.settings.dcBlockHz) },
                                set: { viewModel.settings.dcBlockHz = Int($0) }
                            ),
                            in: 40...90,
                            step: 5
                        )
                        Text(viewModel.settings.dcBlockHz == 80
                             ? "\(viewModel.settings.dcBlockHz) Hz · default"
                             : "\(viewModel.settings.dcBlockHz) Hz")
                            .frame(width: 110, alignment: .trailing)
                    }
                }

                GridRow {
                    Text("Loudness Norm")
                    Toggle("Enable", isOn: $viewModel.settings.loudnormEnabled)
                        .toggleStyle(.switch)
                }

                GridRow {
                    Text("Target")
                    HStack {
                        Slider(value: $viewModel.settings.loudnormTarget, in: -35 ... -16, step: 1)
                        Text(viewModel.settings.loudnormTarget == -30
                             ? String(format: "%.0f LUFS · default", viewModel.settings.loudnormTarget)
                             : String(format: "%.0f LUFS", viewModel.settings.loudnormTarget))
                            .frame(width: 130, alignment: .trailing)
                    }
                    .disabled(!viewModel.settings.loudnormEnabled)
                }

                GridRow {
                    Text("Output Dir")
                    HStack {
                        if let path = viewModel.settings.outputDirectoryPath {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.caption)
                            Button("Reset") {
                                viewModel.settings.outputDirectoryPath = nil
                            }
                            .controlSize(.small)
                        } else {
                            Text("Same as source")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
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
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial)
    }
}
