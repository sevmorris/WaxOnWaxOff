import SwiftUI
import AppKit

struct WaxOffSettingsView: View {
    @Bindable var viewModel: DeliveryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Sample Rate")
                    Picker("", selection: $viewModel.settings.sampleRate) {
                        Text("44.1 kHz").tag(44100)
                        Text("48 kHz").tag(48000)
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("Output")
                    Picker("", selection: $viewModel.settings.outputMode) {
                        Text("WAV").tag(OutputMode.wav)
                        Text("MP3").tag(OutputMode.mp3)
                        Text("Both").tag(OutputMode.both)
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("MP3 Bitrate")
                    Picker("", selection: $viewModel.settings.mp3Bitrate) {
                        Text("128 kbps").tag(128)
                        Text("160 kbps").tag(160)
                        Text("192 kbps").tag(192)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(viewModel.settings.outputMode == .wav)
                .opacity(viewModel.settings.outputMode == .wav ? 0.4 : 1)

                GridRow {
                    Text("True Peak")
                    HStack {
                        Slider(value: $viewModel.settings.truePeak, in: -3.0 ... -0.1, step: 0.1)
                        Text("\(viewModel.settings.truePeakString) dBTP")
                            .frame(width: 90, alignment: .trailing)
                            .monospacedDigit()
                    }
                }

                GridRow {
                    Text("Target LUFS")
                    HStack {
                        Slider(value: $viewModel.settings.targetLUFS, in: -24 ... -14, step: 1)
                        Text(viewModel.settings.targetLUFS == viewModel.settings.targetLUFS.rounded()
                             ? "\(Int(viewModel.settings.targetLUFS)) LUFS"
                             : String(format: "%.1f LUFS", viewModel.settings.targetLUFS))
                            .frame(width: 90, alignment: .trailing)
                            .monospacedDigit()
                    }
                }

                GridRow {
                    Text("Phase Rotation")
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
        .frame(minHeight: 280, alignment: .top)
    }
}
