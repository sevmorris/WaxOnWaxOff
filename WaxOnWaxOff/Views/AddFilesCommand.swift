import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @MainActor
    static func present(_ action: AddFilesAction) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        // Folders are the reason this is "Add Files or Folder…" rather than
        // "Open…": the queue coordinator walks a folder and its subfolders.
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose audio files, or a folder to scan."

        // Filter to what the queue will actually accept. Anything without a
        // recognized type is left off rather than guessed at — the filter is a
        // convenience, and `addFiles` still rejects and reports whatever slips
        // through, exactly as it does for a drop.
        let types = FileQueueCoordinator.defaultValidExtensions
            .compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }

        guard panel.runModal() == .OK else { return }
        action.perform(panel.urls)
    }
}
