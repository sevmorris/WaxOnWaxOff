import Foundation
import Observation

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
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            name: "Defaults",
            settings: WaxOnSettings()
        ),
        WaxOnPreset(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!,
            name: "Edit Prep",
            settings: WaxOnSettings(
                sampleRate: .s44100,
                outputChannels: .mono,
                channel: .left,
                limitDb: -1.0,
                loudnormEnabled: true,
                loudnormTarget: -30.0,
                dcBlockHz: 80
            )
        ),
        WaxOnPreset(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
            name: "Edit Prep EBU",
            settings: WaxOnSettings(
                sampleRate: .s44100,
                outputChannels: .mono,
                channel: .left,
                limitDb: -1.0,
                loudnormEnabled: true,
                loudnormTarget: -23.0,
                dcBlockHz: 80
            )
        ),
        WaxOnPreset(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!,
            name: "Mix",
            settings: WaxOnSettings(
                sampleRate: .s44100,
                outputChannels: .stereo,
                channel: .left,
                limitDb: -1.0,
                loudnormEnabled: true,
                loudnormTarget: -24.0,
                dcBlockHz: 20
            )
        )
    ]
}

@Observable
final class WaxOnPresetStore {
    var presets: [WaxOnPreset] = []
    var selectedPresetID: UUID?

    private let userDefaultsKey = "WaxOnUserPresets"

    init() {
        loadPresets()
    }

    var allPresets: [WaxOnPreset] {
        WaxOnPreset.builtIn + presets
    }

    var selectedPreset: WaxOnPreset? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    func savePreset(name: String, settings: WaxOnSettings) {
        let preset = WaxOnPreset(name: name, settings: settings)
        presets.append(preset)
        saveToUserDefaults()
    }

    func deletePreset(_ preset: WaxOnPreset) {
        presets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
        saveToUserDefaults()
    }

    func isBuiltIn(_ preset: WaxOnPreset) -> Bool {
        WaxOnPreset.builtIn.contains { $0.id == preset.id }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        presets = (try? JSONDecoder().decode([WaxOnPreset].self, from: data)) ?? []
    }

    private func saveToUserDefaults() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
