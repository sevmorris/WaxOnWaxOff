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
    }

    var sampleRate: SampleRate = .s44100
    var outputChannels: OutputChannels = .mono
    var channel: MonoChannel = .left
    var limitDb: Double = -1.0
    var loudnormEnabled: Bool = false
    var loudnormTarget: Double = -30.0
    var dcBlockHz: Int = 80
    var noiseReductionEnabled: Bool = false
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
