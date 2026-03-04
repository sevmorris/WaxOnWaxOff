import SwiftUI

struct WaxOnPresetPicker: View {
    @Bindable var viewModel: ContentViewModel
    @State private var showingSaveSheet = false
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
                    Menu("Delete Preset") {
                        ForEach(viewModel.presetStore.presets) { preset in
                            Button(preset.name, role: .destructive) {
                                viewModel.presetStore.deletePreset(preset)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text(currentPresetName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 160, alignment: .leading)
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
    }

    private var currentPresetName: String {
        viewModel.presetStore.selectedPreset?.name ?? "Custom"
    }
}
