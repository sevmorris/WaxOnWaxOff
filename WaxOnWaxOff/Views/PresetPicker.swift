import SwiftUI

struct WaxOffPresetPicker: View {
    @Bindable var viewModel: DeliveryViewModel
    @State private var showingSaveSheet = false
    @State private var showingManageSheet = false
    @State private var newPresetName = ""

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Built-in Presets") {
                    ForEach(WaxOffPreset.builtIn) { preset in
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
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(minWidth: 120, maxWidth: 200, alignment: .leading)
            .help(currentPresetName)
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
            WaxOffManagePresetsSheet(viewModel: viewModel)
        }
    }

    private var currentPresetName: String {
        viewModel.presetStore.selectedPreset?.name ?? "Custom"
    }
}

struct SavePresetSheet: View {
    @Binding var presetName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Preset")
                .font(.headline)

            TextField("Preset Name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }

                Button("Save") {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.isEmpty)
            }
        }
        .padding(24)
    }
}
