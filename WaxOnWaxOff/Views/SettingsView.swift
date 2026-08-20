import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OUTPUT FORMAT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.brandAccent.opacity(0.8))
                    .kerning(0.4)
                    .padding(.top, 6)
                    .padding(.horizontal, 2)

                row("Sample Rate") {
                    LabeledToggleSwitch(
                        selection: $viewModel.settings.sampleRate,
                        leftLabel: "44.1 kHz",
                        leftValue: WaxOnSettings.SampleRate.s44100,
                        rightLabel: "48 kHz",
                        rightValue: WaxOnSettings.SampleRate.s48000
                    )
                    .frame(maxWidth: .infinity)
                }

                row("Channels") {
                    VStack(alignment: .leading, spacing: 4) {
                        // Three modes, so a segmented Picker rather than the
                        // two-way LabeledToggleSwitch — matching how WaxOff
                        // renders its three-case Output setting.
                        Picker("", selection: $viewModel.settings.outputChannels) {
                            Text("Mono").tag(WaxOnSettings.OutputChannels.mono)
                            Text("Stereo").tag(WaxOnSettings.OutputChannels.stereo)
                            Text("Split L/R").tag(WaxOnSettings.OutputChannels.splitLR)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        // The manual makes this case in Tips & Workflow, which
                        // is three screens from the control that needs it.
                        Text("Use Mono for one microphone, Stereo to keep a stereo recording intact, and Split L/R when one file holds two microphones — each channel is prepped on its own and written as a separate mono file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                channelRow

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text("OUTPUT DIR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.brandAccent.opacity(0.8))
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

    private var channelRow: some View {
        let channelEnabled = viewModel.settings.outputChannels == .mono
        return VStack(alignment: .leading, spacing: 5) {
            Text("SOURCE CHANNEL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
                .opacity(channelEnabled ? 1 : 0.4)
            LabeledToggleSwitch(
                selection: $viewModel.settings.channel,
                leftLabel: "Left",
                leftValue: WaxOnSettings.MonoChannel.left,
                rightLabel: "Right",
                rightValue: WaxOnSettings.MonoChannel.right
            )
            .frame(maxWidth: .infinity)
            .opacity(channelEnabled ? 1 : 0.4)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .disabled(!channelEnabled)
        .help(channelEnabled ? "" : "Only applies in Mono output mode")
    }

    @ViewBuilder
    private func row<Content: View>(
        _ label: String?,
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
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
