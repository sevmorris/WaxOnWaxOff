import Foundation

private extension UUID {
    /// Used only for hardcoded built-in-preset IDs declared at file scope.
    /// These are constants in source — a malformed literal here means a typo
    /// in a future commit, not a runtime data problem; the precondition turns
    /// such a typo into a hard launch crash rather than silently allocating
    /// random UUIDs that would invalidate users' selectedPresetID on disk.
    init(knownValid string: String) {
        guard let uuid = UUID(uuidString: string) else {
            preconditionFailure("Built-in preset UUID literal is malformed (commit typo, not a runtime issue): \(string)")
        }
        self = uuid
    }
}

struct WaxOffPreset: Identifiable, Codable, Equatable, PresetCodable {
    typealias StoredSettings = WaxOffSettings

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
