import Foundation
import Observation

private extension UUID {
    init(knownValid string: String) {
        guard let uuid = UUID(uuidString: string) else {
            preconditionFailure("Invalid built-in UUID constant: \(string)")
        }
        self = uuid
    }
}

// MARK: - WaxOnPresetStore

@Observable
final class WaxOnPresetStore {
    var presets: [WaxOnPreset] = []
    var selectedPresetID: UUID?

    private let userDefaultsKey = "WaxOnUserPresets"
    private let selectedPresetKey = "WaxOnSelectedPresetID"

    init() {
        loadPresets()
        if let idString = UserDefaults.standard.string(forKey: selectedPresetKey),
           let id = UUID(uuidString: idString) {
            selectedPresetID = id
        }
    }

    var allPresets: [WaxOnPreset] {
        WaxOnPreset.builtIn + presets
    }

    var selectedPreset: WaxOnPreset? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    func savePreset(_ preset: WaxOnPreset) {
        presets.append(preset)
        persist()
        selectPreset(preset.id)
    }

    func deletePreset(_ preset: WaxOnPreset) {
        presets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id { selectPreset(nil) }
        persist()
    }

    func updatePreset(id: UUID, name: String?, settings: WaxOnSettings?) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            presets[index].name = trimmed
        }
        if let settings {
            presets[index].settings = settings
        }
        persist()
    }

    func selectPreset(_ id: UUID?) {
        selectedPresetID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: selectedPresetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedPresetKey)
        }
    }

    func isBuiltIn(_ preset: WaxOnPreset) -> Bool {
        WaxOnPreset.builtIn.contains { $0.id == preset.id }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        presets = (try? JSONDecoder().decode([WaxOnPreset].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

// MARK: -

struct WaxOnPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var settings: WaxOnSettings

    init(id: UUID = UUID(), name: String, settings: WaxOnSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    static let builtIn: [WaxOnPreset] = [
        WaxOnPreset(
            id: UUID(knownValid: "A0000000-0000-0000-0000-000000000001"),
            name: "Defaults",
            settings: WaxOnSettings()
        ),
        WaxOnPreset(
            id: UUID(knownValid: "A0000000-0000-0000-0000-000000000002"),
            name: "Edit Prep",
            settings: WaxOnSettings(
                sampleRate: .s44100,
                outputChannels: .mono,
                channel: .left,

                loudnormEnabled: true,
                loudnormTarget: -30.0,
                highPassEnabled: true
            )
        ),
        WaxOnPreset(
            id: UUID(knownValid: "A0000000-0000-0000-0000-000000000003"),
            name: "Edit Prep EBU",
            settings: WaxOnSettings(
                sampleRate: .s44100,
                outputChannels: .mono,
                channel: .left,

                loudnormEnabled: true,
                loudnormTarget: -23.0,
                highPassEnabled: true
            )
        ),
    ]
}

