import Foundation
import Observation

struct Preset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var settings: WaxOffSettings

    init(id: UUID = UUID(), name: String, settings: WaxOffSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    static let builtIn: [Preset] = [
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Podcast Standard",
            settings: WaxOffSettings(
                targetLUFS: -18,
                truePeak: -1.0,
                lra: 11.0,
                outputMode: .both,
                mp3Bitrate: 160,
                sampleRate: 44100,
                phaseRotationEnabled: true
            )
        ),
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Podcast Loud",
            settings: WaxOffSettings(
                targetLUFS: -16,
                truePeak: -1.0,
                lra: 11.0,
                outputMode: .both,
                mp3Bitrate: 160,
                sampleRate: 44100,
                phaseRotationEnabled: true
            )
        ),
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "WAV Only (Mastering)",
            settings: WaxOffSettings(
                targetLUFS: -18,
                truePeak: -1.0,
                lra: 11.0,
                outputMode: .wav,
                mp3Bitrate: 160,
                sampleRate: 48000,
                phaseRotationEnabled: true
            )
        )
    ]
}

@Observable
final class PresetStore {
    var presets: [Preset] = []
    var selectedPresetID: UUID?

    private let userDefaultsKey = "WaxOffUserPresets"

    init() {
        loadPresets()
    }

    var allPresets: [Preset] {
        Preset.builtIn + presets
    }

    var selectedPreset: Preset? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    func savePreset(name: String, settings: WaxOffSettings) {
        let preset = Preset(name: name, settings: settings)
        presets.append(preset)
        saveToUserDefaults()
    }

    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
        saveToUserDefaults()
    }

    func isBuiltIn(_ preset: Preset) -> Bool {
        Preset.builtIn.contains { $0.id == preset.id }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        presets = (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    private func saveToUserDefaults() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
