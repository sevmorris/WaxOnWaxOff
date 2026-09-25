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
                defaults.set(mode.rawValue, forKey: "lastMode")
            }
        }
    }

    /// Where the last mode is read from and saved to.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: "lastMode"),
           let restored = AppMode(rawValue: saved) {
            mode = restored
        }
    }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. this @State value being discarded at app teardown.
    // Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}
}
