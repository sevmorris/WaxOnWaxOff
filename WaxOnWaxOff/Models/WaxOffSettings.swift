import Foundation

enum OutputMode: String, Codable, CaseIterable {
    case wav  = "WAV"
    case mp3  = "MP3"
    case both = "Both"
}

struct WaxOffSettings: Codable, Equatable, Sendable {
    var targetLUFS: Double = -18
    var truePeak: Double = -1.0
    var lra: Double = 9.0
    var outputMode: OutputMode = .both
    var mp3Bitrate: Int = 160
    var sampleRate: Int = 44100
    var outputDirectoryPath: String? = nil
    /// True single-channel delivery for mono sources — skips the dual-mono upmix.
    /// Only applies when the source is itself mono; inert for stereo sources.
    /// Default false preserves the existing dual-mono-stereo behavior.
    var monoDelivery: Bool = false

    static let `default` = WaxOffSettings()

    private static let storageKey = "WaxOffSettings"

    static func load() -> WaxOffSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(WaxOffSettings.self, from: data)
        else { return WaxOffSettings() }
        // LRA was never user-configurable; anyone with the prior 11.0 default
        // gets bumped to the new 9.0 default automatically.
        if settings.lra == 11.0 {
            settings.lra = 9.0
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var targetLUFSString: String {
        targetLUFS == targetLUFS.rounded() ? "\(Int(targetLUFS))" : String(format: "%.1f", targetLUFS)
    }

    var truePeakString: String {
        String(format: "%.1f", truePeak)
    }

}

// Custom decoder so that adding a new property in a future version never
// invalidates existing UserDefaults blobs — missing keys fall back to the
// property default instead of failing the whole decode.
extension WaxOffSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WaxOffSettings()
        self.init(
            targetLUFS:          try c.decodeIfPresent(Double.self,     forKey: .targetLUFS)         ?? d.targetLUFS,
            truePeak:            try c.decodeIfPresent(Double.self,     forKey: .truePeak)            ?? d.truePeak,
            lra:                 try c.decodeIfPresent(Double.self,     forKey: .lra)                 ?? d.lra,
            outputMode:          try c.decodeIfPresent(OutputMode.self, forKey: .outputMode)          ?? d.outputMode,
            mp3Bitrate:          try c.decodeIfPresent(Int.self,        forKey: .mp3Bitrate)          ?? d.mp3Bitrate,
            sampleRate:          try c.decodeIfPresent(Int.self,        forKey: .sampleRate)          ?? d.sampleRate,
            outputDirectoryPath: try c.decodeIfPresent(String.self,     forKey: .outputDirectoryPath) ?? d.outputDirectoryPath,
            monoDelivery:        try c.decodeIfPresent(Bool.self,       forKey: .monoDelivery)        ?? d.monoDelivery
        )
    }
}
