import Foundation

struct WaxOnSettings: Codable, Equatable, Sendable {
    enum SampleRate: Int, CaseIterable, Codable, Sendable {
        case s44100 = 44100
        case s48000 = 48000
    }

    enum MonoChannel: String, CaseIterable, Codable, Sendable {
        case left
        case right
    }

    enum OutputChannels: String, CaseIterable, Codable, Sendable {
        case mono
        case stereo
        /// Two-microphone recordings with a different speaker on each channel:
        /// each channel is prepped independently and written as its own mono
        /// file. Requires a 2-channel source; anything else falls back to the
        /// single-file mono path with a warning.
        case splitLR
    }

    var sampleRate: SampleRate = .s44100
    var outputChannels: OutputChannels = .mono
    var channel: MonoChannel = .left
    var loudnormEnabled: Bool = false
    var loudnormTarget: Double = -30.0
    var highPassEnabled: Bool = true
    var phaseRotationEnabled: Bool = true
    var dynamicLevelingEnabled: Bool = false
    var dynamicLevelingAmount: Double = 0.5
    var outputDirectoryPath: String? = nil

    private static let storageKey = "WaxOnSettings"

    static func load() -> WaxOnSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(WaxOnSettings.self, from: data)
        else {
            return WaxOnSettings()
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// Custom decoder lives in an extension so the synthesized memberwise initializer
// remains available. Any missing key falls back to the property default — adding
// a new field to a persisted struct won't invalidate existing UserDefaults blobs.
extension WaxOnSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WaxOnSettings()
        self.init(
            sampleRate:             try c.decodeIfPresent(SampleRate.self,     forKey: .sampleRate)            ?? d.sampleRate,
            outputChannels:         try c.decodeIfPresent(OutputChannels.self, forKey: .outputChannels)        ?? d.outputChannels,
            channel:                try c.decodeIfPresent(MonoChannel.self,    forKey: .channel)               ?? d.channel,
            loudnormEnabled:        try c.decodeIfPresent(Bool.self,           forKey: .loudnormEnabled)       ?? d.loudnormEnabled,
            loudnormTarget:         try c.decodeIfPresent(Double.self,         forKey: .loudnormTarget)        ?? d.loudnormTarget,
            highPassEnabled:        try c.decodeIfPresent(Bool.self,           forKey: .highPassEnabled)       ?? d.highPassEnabled,
            phaseRotationEnabled:   try c.decodeIfPresent(Bool.self,           forKey: .phaseRotationEnabled)  ?? d.phaseRotationEnabled,
            dynamicLevelingEnabled: try c.decodeIfPresent(Bool.self,           forKey: .dynamicLevelingEnabled) ?? d.dynamicLevelingEnabled,
            dynamicLevelingAmount:  try c.decodeIfPresent(Double.self,         forKey: .dynamicLevelingAmount) ?? d.dynamicLevelingAmount,
            outputDirectoryPath:    try c.decodeIfPresent(String.self,         forKey: .outputDirectoryPath)   ?? d.outputDirectoryPath
        )
    }
}
