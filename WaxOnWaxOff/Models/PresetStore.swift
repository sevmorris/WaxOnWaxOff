import Foundation
import Observation

/// Shared shape for WaxOn and WaxOff presets — both modes store a named
/// snapshot of mode-specific settings keyed by UUID.
struct ManagedPresetRow: Identifiable {
    let id: UUID
    let name: String
}

protocol PresetCodable: Identifiable, Codable, Equatable where ID == UUID {
    associatedtype StoredSettings: Codable & Equatable
    nonisolated var id: UUID { get }
    nonisolated var name: String { get set }
    nonisolated var settings: StoredSettings { get set }
}

// MARK: - Persistence helpers

private enum PresetPersistence {
    static func load<P: PresetCodable>(key: String, from defaults: UserDefaults) -> [P] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([P].self, from: data)) ?? []
    }

    static func save<P: PresetCodable>(_ presets: [P], key: String, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }

    static func loadSelectedID(key: String, from defaults: UserDefaults) -> UUID? {
        guard let idString = defaults.string(forKey: key),
              let id = UUID(uuidString: idString) else { return nil }
        return id
    }

    static func saveSelectedID(_ id: UUID?, key: String, to defaults: UserDefaults) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - WaxOn

/// UserDefaults-backed WaxOn preset store. Split from a generic type so Release
/// builds avoid a Swift 6.2 optimizer crash in `@Observable` generic `deinit`.
@Observable
@MainActor
final class WaxOnPresetStore {
    var presets: [WaxOnPreset] = []
    var selectedPresetID: UUID?

    private let builtIn = WaxOnPreset.builtIn
    /// Where presets and the selection are loaded from and saved to.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        presets = PresetPersistence.load(key: "WaxOnUserPresets", from: defaults)
        selectedPresetID = PresetPersistence.loadSelectedID(key: "WaxOnSelectedPresetID", from: defaults)
    }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. this store is owned by the WaxOn view model and released with it
    // when the window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    var allPresets: [WaxOnPreset] { builtIn + presets }

    var selectedPreset: WaxOnPreset? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    var managedRows: [ManagedPresetRow] {
        presets.map { ManagedPresetRow(id: $0.id, name: $0.name) }
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
        PresetPersistence.saveSelectedID(id, key: "WaxOnSelectedPresetID", to: defaults)
    }

    func isBuiltIn(_ preset: WaxOnPreset) -> Bool {
        builtIn.contains { $0.id == preset.id }
    }

    private func persist() {
        PresetPersistence.save(presets, key: "WaxOnUserPresets", to: defaults)
    }
}

// MARK: - WaxOff

@Observable
@MainActor
final class WaxOffPresetStore {
    var presets: [WaxOffPreset] = []
    var selectedPresetID: UUID?

    private let builtIn = WaxOffPreset.builtIn
    /// Where presets and the selection are loaded from and saved to.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        presets = PresetPersistence.load(key: "WaxOffUserPresets", from: defaults)
        selectedPresetID = PresetPersistence.loadSelectedID(key: "WaxOffSelectedPresetID", from: defaults)
    }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. this store is owned by the WaxOff view model and released with it
    // when the window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    var allPresets: [WaxOffPreset] { builtIn + presets }

    var selectedPreset: WaxOffPreset? {
        guard let id = selectedPresetID else { return nil }
        return allPresets.first { $0.id == id }
    }

    var managedRows: [ManagedPresetRow] {
        presets.map { ManagedPresetRow(id: $0.id, name: $0.name) }
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

    func updatePreset(id: UUID, name: String?, settings: WaxOffSettings?) {
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
        PresetPersistence.saveSelectedID(id, key: "WaxOffSelectedPresetID", to: defaults)
    }

    func isBuiltIn(_ preset: WaxOffPreset) -> Bool {
        builtIn.contains { $0.id == preset.id }
    }

    private func persist() {
        PresetPersistence.save(presets, key: "WaxOffUserPresets", to: defaults)
    }
}
