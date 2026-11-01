import Foundation

/// Whether any window has work running. Each window has its own view model, so
/// nothing else can answer for the whole app, and an update must not relaunch
/// the app in the middle of that work.
@MainActor
enum BatchActivity {
    private static var running = Set<ObjectIdentifier>()

    static var isRunning: Bool { !running.isEmpty }

    static func set(_ owner: AnyObject, running isRunning: Bool) {
        if isRunning {
            running.insert(ObjectIdentifier(owner))
        } else {
            running.remove(ObjectIdentifier(owner))
        }
    }
}
