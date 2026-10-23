import SwiftUI

struct WaxOnPresetPicker: View {
    @Bindable var viewModel: ContentViewModel
    @State private var showingSaveSheet = false
    @State private var showingManageSheet = false
    @State private var newPresetName = ""

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Built-in Presets") {
                    ForEach(WaxOnPreset.builtIn) { preset in
                        Button(preset.name) {
                            viewModel.applyPreset(preset)
                        }
                    }
                }

                if !viewModel.presetStore.presets.isEmpty {
                    Section("Custom Presets") {
                        ForEach(viewModel.presetStore.presets) { preset in
                            Button(preset.name) {
                                viewModel.applyPreset(preset)
                            }
                        }
                    }
                }

                Divider()

                Button("Save Current Settings…") {
                    newPresetName = ""
                    showingSaveSheet = true
                }

                if !viewModel.presetStore.presets.isEmpty {
                    Button("Manage Presets…") {
                        showingManageSheet = true
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text(currentPresetName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 160, alignment: .leading)
            .help(pickerHelp)
        }
        .sheet(isPresented: $showingSaveSheet) {
            SavePresetSheet(presetName: $newPresetName) {
                if !newPresetName.isEmpty {
                    viewModel.saveCurrentAsPreset(name: newPresetName)
                }
                showingSaveSheet = false
            } onCancel: {
                showingSaveSheet = false
            }
        }
        .sheet(isPresented: $showingManageSheet) {
            WaxOnManagePresetsSheet(viewModel: viewModel)
        }
    }

    /// "(Modified)" is the part that has to survive a long name, so the
    /// label truncates in the middle.
    private var currentPresetName: String {
        guard let preset = viewModel.presetStore.selectedPreset else { return "Custom" }
        return viewModel.presetIsModified ? "\(preset.name) (Modified)" : preset.name
    }

    private var pickerHelp: String {
        guard let preset = viewModel.presetStore.selectedPreset else { return "Custom" }
        return viewModel.presetIsModified
            ? "The settings differ from \(preset.name). Choose it again to go back to it."
            : preset.name
    }
}
