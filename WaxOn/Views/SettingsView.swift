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
                    Text("Limiter")
                    HStack {
                        Slider(value: $viewModel.settings.limitDb, in: -6 ... -0.1, step: 0.1)
                        Text(String(format: "%.1f dB", viewModel.settings.limitDb))
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }

            DisclosureGroup(isExpanded: $viewModel.showAdvanced) {
                advancedSettings
                    .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private var advancedSettings: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("High Pass")
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.settings.dcBlockHz) },
                            set: { viewModel.settings.dcBlockHz = Int($0) }
                        ),
                        in: 20...150,
                        step: 5
                    )
                    Text(viewModel.settings.dcBlockHz == 70
                         ? "\(viewModel.settings.dcBlockHz) Hz · default"
                         : "\(viewModel.settings.dcBlockHz) Hz")
                        .frame(width: 110, alignment: .trailing)
                }
            }

            GridRow {
                Text("True Peak")
                Toggle("Enable", isOn: $viewModel.settings.truePeakEnabled)
                    .toggleStyle(.switch)
            }

            GridRow {
                Text("Oversample")
                Stepper(value: $viewModel.settings.truePeakOversample, in: 1...8) {
                    Text("\(viewModel.settings.truePeakOversample)x")
                }
                .disabled(!viewModel.settings.truePeakEnabled)
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
                Text("Attack")
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.settings.attackMs) },
                            set: { viewModel.settings.attackMs = Int($0) }
                        ),
                        in: 1...50,
                        step: 1
                    )
                    Text(viewModel.settings.attackMs == 5
                         ? "\(viewModel.settings.attackMs) ms · default"
                         : "\(viewModel.settings.attackMs) ms")
                        .frame(width: 110, alignment: .trailing)
                }
            }

            GridRow {
                Text("Release")
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.settings.releaseMs) },
                            set: { viewModel.settings.releaseMs = Int($0) }
                        ),
                        in: 10...200,
                        step: 5
                    )
                    Text(viewModel.settings.releaseMs == 50
                         ? "\(viewModel.settings.releaseMs) ms · default"
                         : "\(viewModel.settings.releaseMs) ms")
                        .frame(width: 110, alignment: .trailing)
                }
            }

            GridRow {
                Text("Phase Rotate")
                Toggle("150 Hz allpass", isOn: $viewModel.settings.phaseRotationEnabled)
                    .toggleStyle(.switch)
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
                        Text("Next to source file")
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
}
