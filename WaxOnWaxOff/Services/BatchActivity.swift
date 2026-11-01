import Foundation

/// Whether any window has work running. Each window has its own view model, so
/// nothing else can answer for the whole app, and an update must not relaunch
/// the app in the middle of that work. Owners are held weakly: one that goes
/// away with its flag still set has no work left, and must not hold up an update
/// for the rest of the session.
@MainActor
enum BatchActivity {
    private static let running = NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality])

    static var isRunning: Bool { !running.allObjects.isEmpty }

    static func set(_ owner: AnyObject, running isRunning: Bool) {
        if isRunning {
            running.add(owner)
        } else {
            running.remove(owner)
        }
    }
}
