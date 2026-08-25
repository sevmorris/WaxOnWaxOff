import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open panel behind the file list's Add button.
///
/// Until this button existed the only way to get a file into the app was to
/// drag one onto the window, so there was no keyboard- or VoiceOver-reachable
/// path to a populated file list at all. The panel's job is therefore to accept
/// exactly what a drop accepts: several files at once, any of the supported
/// extensions, and folders — which `FileQueueCoordinator.addFiles` expands
/// before it filters.
enum AudioFilePicker {

    /// The content types an open panel must allow so it offers what
    /// `FileQueueCoordinator` will actually accept.
    ///
    /// `allowedContentTypes` rather than the deprecated `allowedFileTypes`, so
    /// the extension-to-type mapping is the system's rather than a second copy
    /// of it here. That mapping can fail, and it fails quietly:
    /// `UTType(filenameExtension:)` answers an *undeclared, dynamic* type
    /// (`dyn.a…`) for an extension the system has no declaration for rather than
    /// answering nil, and a dynamic type matches no file in the panel. Left
    /// alone that would make a format invisible in the picker while
    /// drag-and-drop still took it — the silent drop this must not do. All
    /// eleven defaults resolve to declared types on macOS 15 (checked, not
    /// assumed); this does not depend on that staying true, or on a caller
    /// passing a set that is equally lucky.
    ///
    /// An unresolvable extension widens the list to the `public.audio` /
    /// `public.movie` supertypes instead of dropping the format. Being too
    /// permissive costs nothing here: `addFiles` filters by extension whatever
    /// the panel let through, and already reports the count it skipped. Being
    /// too strict costs a format with no message anywhere.
    ///
    /// `nonisolated` so the tests can call it off the main actor — the project
    /// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would
    /// otherwise pin a plain static function to the main actor.
    nonisolated static func contentTypes(for extensions: Set<String>) -> [UTType] {
        var types: [UTType] = []
        var seen: Set<String> = []
        var hasUnresolved = false

        // Sorted for a stable panel filter order across launches; `Set` has none.
        for ext in extensions.sorted() {
            guard let type = UTType(filenameExtension: ext), type.isDeclared else {
                hasUnresolved = true
                continue
            }
            if seen.insert(type.identifier).inserted {
                types.append(type)
            }
        }

        // `aif` and `aiff` both answer `public.aiff-audio`, so this list is
        // shorter than the extension set even when every extension resolves.
        if hasUnresolved || types.isEmpty {
            for supertype in [UTType.audio, UTType.movie]
            where seen.insert(supertype.identifier).inserted {
                types.append(supertype)
            }
        }

        // Folders have to be in the list, not just enabled with
        // `canChooseDirectories`: once `allowedContentTypes` is set it is the
        // panel's filter, and a folder that matches nothing in it is at best
        // unselectable. `addFiles` expands a folder the same way it does for a
        // drop, so the button would otherwise accept less than the drop does.
        types.append(.folder)
        return types
    }

    /// Runs the panel and answers what the user chose, or an empty array if
    /// they cancelled.
    ///
    /// App-modal `runModal()`, matching the three open panels already in this
    /// codebase. The app is deliberately unsandboxed (see
    /// `WaxOnWaxOff.entitlements`), so the returned URLs need no
    /// security-scoped-access dance before `FileQueueCoordinator` reads them.
    static func chooseFiles(
        validExtensions: Set<String> = FileQueueCoordinator.defaultValidExtensions
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes(for: validExtensions)
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.message = "Choose audio files, or a folder of audio files."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

/// The management strip pinned under the file list: add, remove, clear, and in
/// WaxOff only, metadata.
///
/// These controls used to sit in the top bar next to Process. They belong to a
/// row of the list rather than to the document, which is where macOS puts this
/// kind of control — the `+`/`−` bar under a table in System Settings, Mail's
/// rule list, Xcode's scheme editor.
///
/// It takes values and closures rather than a view model because the two modes
/// have unrelated ones (`ContentViewModel`, `DeliveryViewModel`) and only one of
/// them has metadata. Nothing here decides when a control is live; each caller
/// passes the same rule it enforced before the move.
struct FileListActionBar: View {
    /// Not gated on `canEditFileList`, deliberately, and unlike every other
    /// control here. Adding is what the drop destination already does with no
    /// guard at all, at any point in a batch: a run works from a snapshot taken
    /// at Process and finds its rows by id, so an appended row joins the list
    /// without disturbing it. WaxOff depends on this — dropping files during the
    /// verification tail and then starting the next batch is a documented
    /// workflow. A button that refused what the drop accepts would be the
    /// inconsistency, not the safeguard.
    let add: () -> Void

    let removeSelected: () -> Void
    let canRemove: Bool

    let clearAll: () -> Void
    let canClear: Bool

    /// WaxOff only. Nil in WaxOn, which carries no per-episode podcast metadata
    /// and so gets no button — passing nil removes it from the bar entirely
    /// rather than showing it permanently disabled.
    var editMetadata: (() -> Void)?
    var canEditMetadata: Bool = false

    var body: some View {
        // The pane this sits in is user-resizable from 150 to 600 pt, and the
        // four controls with their titles showing need roughly 210 pt. Rather
        // than pick a breakpoint — which would be a guess about font size,
        // control metrics and any future translation, and would be wrong the
        // moment one of them changed — the two layouts are offered in order and
        // SwiftUI measures. Titles show whenever they fit; below that every
        // control falls back to its icon, which is why each one carries an
        // accessibility label and a tooltip rather than relying on its title.
        ViewThatFits(in: .horizontal) {
            row(showsTitles: true)
            row(showsTitles: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            // A plain hairline, where the top bar rules itself off in the brand
            // accent. The difference is the point: this strip belongs to the
            // list beside it, and should not read as a second toolbar.
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func row(showsTitles: Bool) -> some View {
        let content = HStack(spacing: 4) {
            Button(action: add) {
                Label("Add Files", systemImage: "plus")
            }
            // `+` and `−` stay icon-only at every width. They are the one pair
            // macOS spells as glyphs, and titling them would cost the space the
            // other two need. The inner label style wins over the row's.
            .labelStyle(.iconOnly)
            .help("Add audio files or a folder of audio files")
            .accessibilityLabel("Add Files")

            Button(action: removeSelected) {
                Label("Remove Selected", systemImage: "minus")
            }
            .labelStyle(.iconOnly)
            .disabled(!canRemove)
            .help("Remove the selected files from the list")
            .accessibilityLabel("Remove Selected")

            Spacer(minLength: 8)

            if let editMetadata {
                Button(action: editMetadata) {
                    Label("Metadata", systemImage: "tag")
                }
                .disabled(!canEditMetadata)
                .help("Edit podcast metadata for the selected file")
                .accessibilityLabel("Metadata")
            }

            Button(action: clearAll) {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(!canClear)
            // Carried over with the button. The shortcut lived on Clear in the
            // top bar and still resolves from here — it is bound to the button,
            // not to its position.
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .help("Remove every file from the list")
            .accessibilityLabel("Clear All")
        }
        .buttonStyle(.accessoryBar)
        .controlSize(.small)

        if showsTitles {
            content.labelStyle(.titleAndIcon)
        } else {
            content.labelStyle(.iconOnly)
        }
    }
}

#Preview("WaxOff") {
    FileListActionBar(
        add: {},
        removeSelected: {},
        canRemove: true,
        clearAll: {},
        canClear: true,
        editMetadata: {},
        canEditMetadata: true
    )
    .frame(width: 250)
}

#Preview("WaxOn, minimum width") {
    FileListActionBar(
        add: {},
        removeSelected: {},
        canRemove: false,
        clearAll: {},
        canClear: true
    )
    .frame(width: 150)
}
