import SwiftUI

// MARK: - WaxOn

struct WaxOnManagePresetsSheet: View {
    @Bindable var viewModel: ContentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ManagePresetsShell(
            title: "Manage WaxOn Presets",
            presets: viewModel.presetStore.managedRows,
            onRename: { id, name in
                viewModel.presetStore.updatePreset(id: id, name: name, settings: nil)
            },
            onUpdateSettings: { id in
                viewModel.presetStore.updatePreset(id: id, name: nil, settings: viewModel.settings)
            },
            onDelete: { id in
                if let preset = viewModel.presetStore.presets.first(where: { $0.id == id }) {
                    viewModel.presetStore.deletePreset(preset)
                }
            },
            onDismiss: { dismiss() }
        )
    }
}

// MARK: - WaxOff

struct WaxOffManagePresetsSheet: View {
    @Bindable var viewModel: DeliveryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ManagePresetsShell(
            title: "Manage WaxOff Presets",
            presets: viewModel.presetStore.managedRows,
            onRename: { id, name in
                viewModel.presetStore.updatePreset(id: id, name: name, settings: nil)
            },
            onUpdateSettings: { id in
                viewModel.presetStore.updatePreset(id: id, name: nil, settings: viewModel.settings)
            },
            onDelete: { id in
                if let preset = viewModel.presetStore.presets.first(where: { $0.id == id }) {
                    viewModel.presetStore.deletePreset(preset)
                }
            },
            onDismiss: { dismiss() }
        )
    }
}

// MARK: - Shared UI

private struct ManagePresetsShell: View {
    let title: String
    let presets: [ManagedPresetRow]
    let onRename: (UUID, String) -> Void
    let onUpdateSettings: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var names: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            if presets.isEmpty {
                Text("No custom presets yet. Use “Save Current Settings…” from the preset menu.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Done") {
                    for preset in presets {
                        commitRename(preset.id)
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            names = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0.name) })
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: ManagedPresetRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: binding(for: preset.id, default: preset.name))
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(preset.id) }

            HStack(spacing: 8) {
                Button("Update to Current Settings") {
                    onUpdateSettings(preset.id)
                }
                .controlSize(.small)

                Spacer()

                Button("Delete", role: .destructive) {
                    onDelete(preset.id)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func binding(for id: UUID, default defaultName: String) -> Binding<String> {
        Binding(
            get: { names[id] ?? defaultName },
            set: { names[id] = $0 }
        )
    }

    private func commitRename(_ id: UUID) {
        guard let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        onRename(id, name)
    }
}
