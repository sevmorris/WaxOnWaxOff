import Observation

enum AppMode: String, CaseIterable {
    case waxOn  = "WaxOn"
    case waxOff = "WaxOff"
}

@Observable
final class AppState {
    var mode: AppMode? = nil   // nil = show picker
}
