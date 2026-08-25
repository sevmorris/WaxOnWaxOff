import SwiftUI

/// The active mode's file-adding entry point, published to the menu bar.
///
/// The two modes keep separate queues and separate view models, and those view
/// models are `@State` inside `RootContentView` — so a `.commands` block, which
/// lives up in the `Scene`, cannot reach them directly. `@FocusedValue` is the
/// mechanism SwiftUI provides for exactly this: the visible view publishes what
/// it can do, the menu reads it, and the item disables itself when nothing has
/// published one.
struct AddFilesAction: Equatable {
    /// Which mode published this. Equality is by mode because the closure
    /// cannot be compared, and the mode is the thing that actually changes —
    /// switching WaxOn/WaxOff must be seen as a new value.
    let mode: AppMode
    let perform: @MainActor ([URL]) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.mode == rhs.mode }
}

private struct AddFilesActionKey: FocusedValueKey {
    typealias Value = AddFilesAction
}

extension FocusedValues {
    var addFiles: AddFilesAction? {
        get { self[AddFilesActionKey.self] }
        set { self[AddFilesActionKey.self] = newValue }
    }
}

enum AddFilesPanel {
    /// Open the picker and hand whatever comes back to the mode's own
    /// `addFiles`.
    ///
    /// Deliberately the same entry point drag-and-drop uses. Folder expansion,
    /// extension filtering and the "N files skipped" alert all live in
    /// `FileQueueCoordinator.addFiles`, so routing through it means the menu
    /// and the drop cannot drift apart — and a folder dropped on the window
    /// behaves the same as a folder chosen here.
    ///
    /// The panel is `AudioFilePicker`'s, shared with the file list's `+`
    /// button. This built its own until the button arrived, which left the two
    /// routes into the same queue offering subtly different panels: only one
    /// guarded `UTType.isDeclared`, so only one was safe against an extension
    /// the system has no declaration for, and their messages were worded
    /// differently. Folders remain the reason this reads "Add Files or Folder…"
    /// rather than "Open…" — the queue coordinator walks a folder and its
    /// subfolders.
    ///
    /// The empty guard matches the button's: `addFiles` assigns its result to
    /// `alertMessage`, so handing it a cancelled panel's empty array would
    /// clear a message the user has not read yet.
    @MainActor
    static func present(_ action: AddFilesAction) {
        let urls = AudioFilePicker.chooseFiles()
        guard !urls.isEmpty else { return }
        action.perform(urls)
    }
}
