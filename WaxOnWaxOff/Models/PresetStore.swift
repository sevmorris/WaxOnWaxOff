import Foundation
import Observation

/// Shared shape for WaxOn and WaxOff presets — both modes store a named
/// snapshot of mode-specific settings keyed by UUID. The associated type
/// captures the per-mode settings struct so the generic store stays type-safe
/// (no `Any` boxing through UserDefaults).
///
/// Requirements are `nonisolated` because the project default actor isolation
/// is MainActor; without that override they collide with Identifiable's
/// (nonisolated) `id` requirement.
protocol PresetCodable: Identifiable, Codable, Equatable where ID == UUID {
    associatedtype StoredSettings: Codable & Equatable
    nonisolated var id: UUID { get }
    nonisolated var name: String { get set }
    nonisolated var settings: StoredSettings { get set }
}

/// Generic UserDefaults-backed store for WaxOn / WaxOff presets. Built-in
/// presets are passed in at construction (and are never persisted); user
/// presets sit on top and round-trip via JSON. The two mode-specific stores
/// are `typealias`-shaped on top of this so existing call sites compile
/// unchanged.
@Observable
@MainActor
final class PresetStore<P: PresetCodable> {
    var presets: [P] = []
    var selectedPresetID: UUID?

    @ObservationIgnored private let userDefaultsKey: String
    @ObservationIgnored private let selectedPresetKey: String
    @ObservationIgnored private let builtIn: [P]

    init(userDefaultsKey: String, selectedPresetKey: String, builtIn: [P]) {
        self.userDefaultsKey = userDefaultsKey
        self.selectedPresetKey = selectedPresetKey
        self.builtIn = builtIn
        loadPresets()
        if let idString = UserDefaults.standard.string(forKey: selectedPresetKey),
           let id = UUID(uuidString: idString) {
            selectedPresetID = id
        }
    }

    var allPresets: [P] {
        builtIn + presets
    }

    var selectedPreset: P? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    func savePreset(_ preset: P) {
        presets.append(preset)
        persist()
        selectPreset(preset.id)
    }

    func deletePreset(_ preset: P) {
        presets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id { selectPreset(nil) }
        persist()
    }

    func updatePreset(id: UUID, name: String?, settings: P.StoredSettings?) {
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

    func isBuiltIn(_ preset: P) -> Bool {
        builtIn.contains { $0.id == preset.id }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        presets = (try? JSONDecoder().decode([P].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

// MARK: - Mode-specific stores

typealias WaxOnPresetStore = PresetStore<WaxOnPreset>
typealias WaxOffPresetStore = PresetStore<WaxOffPreset>

extension PresetStore where P == WaxOnPreset {
    convenience init() {
        self.init(
            userDefaultsKey: "WaxOnUserPresets",
            selectedPresetKey: "WaxOnSelectedPresetID",
            builtIn: WaxOnPreset.builtIn
        )
    }
}

extension PresetStore where P == WaxOffPreset {
    convenience init() {
        self.init(
            userDefaultsKey: "WaxOffUserPresets",
            selectedPresetKey: "WaxOffSelectedPresetID",
            builtIn: WaxOffPreset.builtIn
        )
    }
}
