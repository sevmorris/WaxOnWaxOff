import Foundation

private extension UUID {
    /// See `Preset.swift` for the rationale — these literals are constants in
    /// source, so a malformed string is a commit-time typo, not a runtime
    /// issue. Crashing loudly is preferable to allocating random UUIDs that
    /// would invalidate users' selectedPresetID on disk.
    init(knownValid string: String) {
        guard let uuid = UUID(uuidString: string) else {
            preconditionFailure("Built-in preset UUID literal is malformed (commit typo, not a runtime issue): \(string)")
        }
        self = uuid
    }
}

struct WaxOnPreset: Identifiable, Codable, Equatable, PresetCodable {
    typealias StoredSettings = WaxOnSettings

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
        )
    ]
}
