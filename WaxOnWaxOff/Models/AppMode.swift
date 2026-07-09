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

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. this @State value being discarded at app teardown.
    // Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}
}
