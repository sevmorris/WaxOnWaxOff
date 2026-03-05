import Foundation
import Observation

enum AppMode: String, CaseIterable {
    case waxOn  = "WaxOn"
    case waxOff = "WaxOff"
}

@Observable
final class AppState {
    var mode: AppMode? = nil {
        didSet {
            if let mode {
                UserDefaults.standard.set(mode.rawValue, forKey: "lastMode")
            }
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "lastMode"),
           let restored = AppMode(rawValue: saved) {
            mode = restored
        }
    }
}
