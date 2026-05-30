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

// MARK: - WaxOffPresetStore

@Observable
final class WaxOffPresetStore {
    var presets: [WaxOffPreset] = []
    var selectedPresetID: UUID?

    private let userDefaultsKey = "WaxOffUserPresets"
    private let selectedPresetKey = "WaxOffSelectedPresetID"

    init() {
        loadPresets()
        if let idString = UserDefaults.standard.string(forKey: selectedPresetKey),
           let id = UUID(uuidString: idString) {
            selectedPresetID = id
        }
    }

    var allPresets: [WaxOffPreset] {
        WaxOffPreset.builtIn + presets
    }

    var selectedPreset: WaxOffPreset? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    func savePreset(_ preset: WaxOffPreset) {
        presets.append(preset)
        persist()
        selectPreset(preset.id)
    }

    func deletePreset(_ preset: WaxOffPreset) {
        presets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id { selectPreset(nil) }
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

    func isBuiltIn(_ preset: WaxOffPreset) -> Bool {
        WaxOffPreset.builtIn.contains { $0.id == preset.id }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        presets = (try? JSONDecoder().decode([WaxOffPreset].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

// MARK: -

struct WaxOffPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var settings: WaxOffSettings

    init(id: UUID = UUID(), name: String, settings: WaxOffSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    static let builtIn: [WaxOffPreset] = [
        WaxOffPreset(
            id: UUID(knownValid: "00000000-0000-0000-0000-000000000001"),
            name: "Podcast Standard",
            settings: WaxOffSettings(
                targetLUFS: -18,
                truePeak: -1.0,
                lra: 9.0,
                outputMode: .both,
                mp3Bitrate: 160,
                sampleRate: 44100
            )
        ),
        WaxOffPreset(
            id: UUID(knownValid: "00000000-0000-0000-0000-000000000002"),
            name: "Podcast Loud",
            settings: WaxOffSettings(
                targetLUFS: -16,
                truePeak: -1.0,
                lra: 9.0,
                outputMode: .both,
                mp3Bitrate: 160,
                sampleRate: 44100
            )
        ),
        WaxOffPreset(
            id: UUID(knownValid: "00000000-0000-0000-0000-000000000003"),
            name: "WAV Only (Mastering)",
            settings: WaxOffSettings(
                targetLUFS: -18,
                truePeak: -1.0,
                lra: 9.0,
                outputMode: .wav,
                mp3Bitrate: 160,
                sampleRate: 48000
            )
        )
    ]
}

