import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OUTPUT FORMAT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
                    .padding(.top, 6)
                    .padding(.horizontal, 2)

                row("Sample Rate") {
                    Picker("", selection: $viewModel.settings.sampleRate) {
                        Text("44.1 kHz").tag(WaxOnSettings.SampleRate.s44100)
                        Text("48 kHz").tag(WaxOnSettings.SampleRate.s48000)
                    }
                    .pickerStyle(.segmented)
                }

                row("Channels") {
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
                .help(viewModel.settings.outputChannels == .stereo ? "Only applies in Mono output mode" : "")

                Divider().padding(.vertical, 6)

                row("Ceiling") {
                    HStack(spacing: 6) {
                        Slider(value: $viewModel.settings.limitDb, in: -3 ... -1, step: 1)
                        Text(String(format: "%.0f dB", viewModel.settings.limitDb))
                            .font(.system(size: 11).monospaced())
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                row("High Pass", caption: "DC offset is always removed regardless of this setting.") {
                    HStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.settings.highPassHz) },
                                set: { viewModel.settings.highPassHz = Int($0) }
                            ),
                            in: 0...90,
                            step: 5
                        )
                        Text(viewModel.settings.highPassHz == 0 ? "Off" : "\(viewModel.settings.highPassHz) Hz")
                            .font(.system(size: 11).monospaced())
                            .frame(width: 55, alignment: .trailing)
                    }
                }

                row("Phase Rotation", caption: "Allpass at 200 Hz — recovers headroom on asymmetric voice waveforms. Alters waveform phase; avoid on stereo music.") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $viewModel.settings.phaseRotationEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text("200 Hz allpass")
                    }
                }

                Divider().padding(.vertical, 6)

                row("Level Riding") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $viewModel.settings.levelRidingEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Text("Tame loud peaks")
                        }
                        Text("Attenuates loud sections only — never boosts quiet ones")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(viewModel.settings.dynamicLevelingEnabled)
                .opacity(viewModel.settings.dynamicLevelingEnabled ? 0.4 : 1)
                .help(viewModel.settings.dynamicLevelingEnabled ? "Unavailable when Dynamic Leveling is on — it already handles gain control in both directions" : "")

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PANEL / MULTI-VOICE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.4)
                    Text("For recordings with multiple voices at inconsistent levels.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)

                row("Dynamic Leveling") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { viewModel.settings.dynamicLevelingEnabled },
                                set: { newValue in
                                    viewModel.settings.dynamicLevelingEnabled = newValue
                                    if newValue { viewModel.settings.levelRidingEnabled = false }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            Text("dynaudnorm")
                        }
                        Text("Lifts quiet voices, tames loud ones — panel shows, live Q&As. Can cause pumping on solo voice with natural pauses.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                row("Aggressiveness", caption: "Max gain: Gentle +6 dB · Aggressive +15 dB. Audition output before editing.") {
                    HStack(spacing: 6) {
                        Slider(value: $viewModel.settings.dynamicLevelingAmount, in: 0 ... 1)
                        Text(aggressivenessLabel(viewModel.settings.dynamicLevelingAmount))
                            .font(.system(size: 11).monospaced())
                            .frame(width: 68, alignment: .trailing)
                    }
                }
                .disabled(!viewModel.settings.dynamicLevelingEnabled)
                .opacity(!viewModel.settings.dynamicLevelingEnabled ? 0.4 : 1)
                .help(!viewModel.settings.dynamicLevelingEnabled ? "Enable Dynamic Leveling to adjust" : "")

                Divider().padding(.vertical, 6)

                row("Loudness Norm", caption: "Two-pass EBU R128 normalization to a target loudness") {
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
                .help(!viewModel.settings.loudnormEnabled ? "Enable Loudness Norm to adjust" : "")

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
                            .help(path)
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

    private func aggressivenessLabel(_ amount: Double) -> String {
        switch amount {
        case ..<0.25: return "Gentle"
        case ..<0.5:  return "Low"
        case ..<0.75: return "Medium"
        case ..<0.9:  return "High"
        default:      return "Aggressive"
        }
    }

    @ViewBuilder
    private func row<Content: View>(
        _ label: String?,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(0.4)
            }
            content()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
