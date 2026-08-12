import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-episode ID3 metadata editor for one file. Edits a local copy of the
/// file's `EpisodeMetadata` and commits it through `onSave`, so Cancel
/// genuinely discards rather than leaving half-typed values behind.
///
/// The view deliberately knows nothing about `WaxOffSettings` or the file list:
/// everything it needs arrives as a parameter, which is what makes the two
/// static helpers below testable without standing up a view hierarchy.
struct MetadataSheet: View {
    /// Display name of the file being tagged, e.g. `episode-12.wav`.
    let fileName: String
    /// nil while the file is still being analyzed. Chapter timestamps cannot be
    /// range-checked against an unknown length, so parsing skips that check
    /// rather than rejecting every line the user pastes.
    let duration: TimeInterval?
    /// False when the current output mode writes no MP3, in which case nothing
    /// edited here reaches a delivered file. Passed in rather than read from
    /// settings so this view stays independent of the settings model.
    let appliesToOutput: Bool
    let onSave: (EpisodeMetadata) -> Void

    @State private var draft: EpisodeMetadata
    @State private var chapterText: String
    @State private var parseError: String?
    /// Set by `ChapterTableView` while a row's timestamp field holds something
    /// unparsable. Separate from `parseError` because the two have different
    /// causes and both have to block Save.
    @State private var chapterTimeError: String?
    @State private var artworkNote: String?
    /// Why the last dragged file was refused, or nil. Only a drop sets this;
    /// the `Choose…` panel cannot produce an unacceptable file because it
    /// filters by content type before the user can pick.
    @State private var artworkDropError: String?
    @State private var artworkThumbnail: NSImage?
    @State private var isDropTargeted = false
    /// True while a chapter row's time field holds focus, reported up by
    /// `ChapterTableView`. See `settleChapterOrder()`.
    @State private var isEditingChapterTime = false
    @Environment(\.dismiss) private var dismiss

    init(
        fileName: String,
        duration: TimeInterval?,
        appliesToOutput: Bool,
        metadata: EpisodeMetadata,
        onSave: @escaping (EpisodeMetadata) -> Void
    ) {
        self.fileName = fileName
        self.duration = duration
        self.appliesToOutput = appliesToOutput
        self.onSave = onSave
        self._draft = State(initialValue: metadata)
        // Seeded here rather than in `onAppear`: seeding on appear means the
        // text box renders empty for one frame and then mutates, which fires
        // the `onChange` reparse against text the user never typed. `init`
        // makes the first render already correct, and `State(initialValue:)`
        // is only consulted on the first construction so later re-renders of
        // the parent cannot clobber in-progress edits.
        self._chapterText = State(initialValue: Self.text(from: metadata.chapters))
    }

    var body: some View {
        // Two zones, deliberately. Everything editable scrolls; the button row
        // is a sibling of the scroller, not a child, so it is always on screen.
        // Previously the whole sheet was one uncapped VStack: a long chapter
        // list grew the sheet past the window and pushed Cancel and Save off
        // the bottom, leaving a sheet that could be neither saved nor
        // dismissed. A chapter table only makes that easier to hit.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if !appliesToOutput {
                        Label(
                            "Metadata applies to MP3 output only. The current output mode writes no MP3.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    textFields
                    artworkWell
                    chapterEditor
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    // Saving with an unparsable box would silently keep the
                    // last chapters that *did* parse, which no longer match
                    // the text on screen. Same for an unparsable row time: the
                    // model still holds that row's previous start.
                    .disabled(saveBlockedReason != nil)
                    .help(saveBlockedReason ?? "")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        // Width is fixed so the labelled fields line up. The height cap is what
        // keeps the sheet inside the window: `WaxOffMainView` sets the window's
        // content minimum to 624, so 600 always fits and the scroller absorbs
        // any amount of chapter content beyond it.
        .frame(width: 520)
        .frame(minHeight: 420, maxHeight: 600)
        .onChange(of: draft.artworkURL, initial: true) { _, url in
            loadArtwork(url)
        }
    }

    private var saveBlockedReason: String? {
        if parseError != nil { return "Fix the chapter error before saving" }
        if chapterTimeError != nil { return "Fix the chapter time before saving" }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Episode Metadata")
                .font(.headline)
            Text(fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(fileName)
        }
    }

    // MARK: - Text fields

    /// A plain labelled `VStack` rather than a `Form`: `ManagePresetsSheet`
    /// builds its rows this way, and `.formStyle(.columns)` would right-align
    /// two labels against a grid the rest of the sheet does not share.
    private var textFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Podcast Name") {
                TextField("", text: $draft.podcastName, prompt: Text("Shown as the album"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            field("Episode Title") {
                VStack(alignment: .leading, spacing: 3) {
                    // Placeholder, not a pre-filled value: an empty title means
                    // "fall back to the output stem", which is what WaxOff did
                    // before this feature existed. Pre-filling would turn that
                    // fallback into an explicit override the user never chose.
                    TextField("", text: $draft.episodeTitle, prompt: Text(defaultTitle))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Text("Leave empty to use the output file name.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            content()
        }
    }

    /// The stem WaxOff tags with when Episode Title is left empty. Approximate
    /// by one hop: if the delivered name collides in the output directory the
    /// allocator appends a suffix, so the real stem can differ. Close enough
    /// for a placeholder, and never written anywhere.
    private var defaultTitle: String {
        (fileName as NSString).deletingPathExtension
    }

    // MARK: - Artwork

    private var artworkWell: some View {
        field("Artwork") {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    if let url = draft.artworkURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                    } else {
                        Text("No artwork")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // The refusal outranks the dimension note and shows in both
                    // states. Kept in its own property rather than written into
                    // `artworkNote`: that line sits directly under the current
                    // file's name, so "cover.png / Not a PNG or JPEG image"
                    // would read as a verdict on the artwork already set rather
                    // than on the thing just dropped. It also has to appear
                    // when nothing is set at all, where there is no note line.
                    if let artworkDropError {
                        Text(artworkDropError)
                            .font(.caption2)
                            .foregroundStyle(Color.meterCritical)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if draft.artworkURL != nil, let artworkNote {
                        Text(artworkNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Choose…") { chooseArtwork() }
                        .controlSize(.small)
                    if draft.artworkURL != nil {
                        Button("Clear") { draft.artworkURL = nil }
                            .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isDropTargeted ? 1 : 0)
            )
            // The whole well is the target, not just the thumbnail: a 56-point
            // square is a small thing to hit with a dragged file.
            //
            // `isTargeted` can only say that a file is over the well, since the
            // drop machinery hands the URLs over at drop time and not before.
            // Whether it is usable art is decided in `acceptDrop`, which is why
            // a refusal has to be visible afterwards rather than the highlight
            // simply not appearing.
            .dropDestination(for: URL.self) { urls, _ in
                acceptDrop(urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Artwork")
            .accessibilityHint("Drop a PNG or JPEG image here, or use the Choose button.")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let artworkThumbnail {
            Image(nsImage: artworkThumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.secondary.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Choose cover art for this episode."
        panel.prompt = "Choose"
        // App-modal, matching the two existing `Choose…` buttons in the
        // settings views. The app runs unsandboxed (see the entitlements file),
        // so the returned URL needs no security-scoped access dance.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Setting the URL is enough — the `onChange(of: draft.artworkURL)`
        // above reloads the thumbnail and the note from one place, so opening
        // the sheet on a file that already has artwork shows them too.
        draft.artworkURL = url
    }

    /// Returns whether the drop was taken, which is what tells AppKit to show
    /// the accept animation rather than the file snapping back.
    @discardableResult
    private func acceptDrop(_ urls: [URL]) -> Bool {
        switch ArtworkInspector.evaluate(drop: urls) {
        case .accepted(let url):
            // Cleared explicitly as well as in `loadArtwork`: dropping the file
            // that is already set leaves `artworkURL` unchanged, so the
            // `onChange` that normally does this would not fire.
            artworkDropError = nil
            draft.artworkURL = url
            return true
        case .rejected(let reason):
            artworkDropError = reason
            return false
        }
    }

    private func loadArtwork(_ url: URL?) {
        // Cleared here rather than at each call site: every route that changes
        // the artwork — drop, panel, Clear — goes through this, so a stale
        // refusal cannot outlive the thing it was refusing.
        artworkDropError = nil
        guard let url else {
            artworkThumbnail = nil
            artworkNote = nil
            return
        }
        artworkThumbnail = ArtworkInspector.thumbnail(for: url, maxPixelSize: 128)
        artworkNote = ArtworkInspector.note(for: url)
    }

    // MARK: - Chapters

    /// Table first, paste box second. The list is what a returning user comes
    /// back to edit; pasting is the one-off that starts it off. The two halves
    /// are otherwise independent — swapping the order back is moving one block
    /// and rewording the two captions that say which way to look.
    private var chapterEditor: some View {
        field("Chapters") {
            VStack(alignment: .leading, spacing: 6) {
                ChapterTableView(
                    chapters: chaptersFromTable,
                    duration: duration,
                    timeError: $chapterTimeError,
                    isEditingTime: $isEditingChapterTime
                )

                Divider()
                    .padding(.vertical, 4)

                Text("Or paste a list, one per line: MM:SS Title or HH:MM:SS Title. Pasted chapters appear in the list above.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // A fixed height, not a floor. `TextEditor` is itself a scroll
                // view, and inside the sheet's outer `ScrollView` it is offered
                // unbounded height — with only a `minHeight` it grows to fit
                // its content instead of scrolling, which is the same runaway
                // growth the outer scroller was added to prevent. Pinning the
                // height makes it a bounded box that scrolls internally.
                TextEditor(text: $chapterText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 140)
                    .background(.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(parseError == nil ? Color.secondary.opacity(0.3) : Color.meterCritical.opacity(0.7))
                    )
                    .onChange(of: chapterText) { _, _ in reparse() }
                    // The syntax hint above is a sibling `Text`, so VoiceOver
                    // never reads it when focus lands in the editor. The two
                    // fields above announce their `prompt:`; `TextEditor` has
                    // no equivalent, so the hint has to be attached by hand.
                    .accessibilityLabel("Chapters")
                    .accessibilityHint("One per line: minutes colon seconds, or hours colon minutes colon seconds, followed by a title.")

                // Kept with the paste box rather than with the table: the error
                // half of it names a line number in this text.
                status
            }
        }
        // Fires when the last focused time field is left — including for the
        // paste box, since clicking into it takes focus off the row.
        .onChange(of: isEditingChapterTime) { _, editing in
            if !editing { settleChapterOrder() }
        }
    }

    /// The binding the table writes through.
    ///
    /// Note what this is *not*: an `onChange(of: draft.chapters)` observer that
    /// regenerates `chapterText`. That would also fire while the user types in
    /// the paste box — typing `1:30 Intro` parses, sets `draft.chapters`, and
    /// the observer would immediately rewrite the box to the canonical
    /// `01:30 Intro`, moving the caret mid-word. Regeneration has to be scoped
    /// to writes that actually came from the table, so it lives in the setter.
    ///
    /// Assigning `chapterText` fires the editor's own `onChange`, which calls
    /// `reparse()`. That is the whole sync: table → chapters → text → parse →
    /// chapters. It settles in one pass because the table only ever writes
    /// normalized chapters, so the reparse returns exactly what it was given
    /// and `preservingIdentity` hands back the same ids — `draft.chapters` is
    /// then unchanged and nothing fires again. `ChapterTableTests` pins that
    /// fixpoint for every edit the table can make.
    ///
    /// A table edit does overwrite a paste box the user has left in an
    /// unparsable state. That is intentional: the table shows the last chapters
    /// that parsed, so regenerating from a table edit replaces broken text with
    /// text matching what the user was just editing, visibly, and clears the
    /// error rather than leaving the two surfaces permanently disagreeing.
    ///
    /// One case suspends all of that. While a row's *time* field is focused the
    /// table writes a chapter whose start is correct but whose position is not,
    /// because re-sorting under the cursor is what made a half-typed time throw
    /// its row across the list. Sorting and regeneration wait for
    /// `settleChapterOrder()`; the value itself never does.
    private var chaptersFromTable: Binding<[Chapter]> {
        Binding(
            get: { draft.chapters },
            set: { updated in
                draft.chapters = updated
                guard !isEditingChapterTime else {
                    // A time field is focused, so `updated` may be out of
                    // order and regenerating from it would produce text that
                    // `ChapterParser` rejects as `.outOfOrder` — a red error
                    // flashing under a half-typed time, and a paste box the
                    // user is not even looking at rewriting itself.
                    //
                    // The value is committed above regardless; only the text
                    // and the ordering wait for `settleChapterOrder()`.
                    validate(ChapterTableView.sorted(updated))
                    return
                }
                regeneratePasteBox(from: updated)
            }
        )
    }

    /// Restores the ordering the rest of the app depends on, and resyncs the
    /// paste box, once the user has left the time field.
    ///
    /// `ChapterMetadataFile.contents(for:duration:)` is documented as requiring
    /// a sorted array and deliberately does not re-sort — an unsorted one
    /// yields a chapter whose END precedes its START. Nothing unsorted may
    /// escape this sheet, so the two exits are covered: this, on blur, and
    /// `committed(_:)`, for the Save that arrives while a field still has
    /// focus.
    private func settleChapterOrder() {
        let ordered = ChapterTableView.sorted(draft.chapters)
        draft.chapters = ordered
        regeneratePasteBox(from: ordered)
    }

    private func regeneratePasteBox(from chapters: [Chapter]) {
        let regenerated = Self.text(from: chapters)
        guard regenerated != chapterText else {
            // Same text, so the editor's `onChange` will not fire. Reparse by
            // hand so `parseError` still reflects what the table just did — an
            // edit that duplicates a start, for instance, has to surface even
            // when the text is identical.
            reparse()
            return
        }
        chapterText = regenerated
    }

    /// Refreshes `parseError` for chapters that have not been written to the
    /// paste box, without touching either the box or `draft.chapters`.
    ///
    /// This is what keeps Save honestly disabled during a deferred edit. Retype
    /// one row's time to match another's and the list stops being valid
    /// chapters; before the deferral that surfaced immediately, and it still
    /// has to, or Save would go live on an array the parser rejects.
    private func validate(_ chapters: [Chapter]) {
        let limit = duration ?? .greatestFiniteMagnitude
        switch ChapterParser.parse(Self.text(from: chapters), duration: limit) {
        case .success:
            parseError = nil
        case .failure(let error):
            parseError = error.errorDescription
        }
    }

    @ViewBuilder
    private var status: some View {
        if let parseError {
            Label(parseError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.meterCritical)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.chapters.isEmpty
                     ? "No chapters."
                     : "\(draft.chapters.count) chapter\(draft.chapters.count == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if duration == nil {
                    Text("This file is still being analyzed, so chapter times are not yet checked against its length.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func reparse() {
        // With an unknown duration there is nothing to range-check against, so
        // parse against an unbounded length. Passing 0 here would trip
        // `ChapterParser`'s `start < duration` guard on every single line and
        // tell the user their perfectly good chapters are past the end of a
        // file whose length we simply have not measured yet.
        let limit = duration ?? .greatestFiniteMagnitude
        switch ChapterParser.parse(chapterText, duration: limit) {
        case .success(let parsed):
            draft.chapters = Self.preservingIdentity(of: draft.chapters, in: parsed)
            parseError = nil
        case .failure(let error):
            // `draft.chapters` deliberately keeps its last good value; Save is
            // disabled while `parseError` is set so that stale value cannot be
            // committed behind the user's back.
            parseError = error.errorDescription
        }
    }

    private func save() {
        onSave(Self.committed(draft))
        dismiss()
    }

    /// What Save actually commits.
    ///
    /// Static and pure so the two normalizations below are testable, and
    /// because both of them are silent corruption if they are ever dropped.
    ///
    /// The sort is not belt and braces. A time field commits on every parseable
    /// keystroke precisely because a macOS button click does not reliably end
    /// field editing — so the click that reaches Save is exactly the one that
    /// may not have blurred the field, and `settleChapterOrder()` may therefore
    /// never have run. Committing that array unsorted would hand
    /// `ChapterMetadataFile` a list it documents as impossible and get back a
    /// chapter whose END precedes its START.
    nonisolated static func committed(_ draft: EpisodeMetadata) -> EpisodeMetadata {
        var committed = draft
        // Trim here rather than only in the encoder: `EpisodeMetadata.isEmpty`
        // tests the raw strings, so a stray space would make an otherwise
        // untagged file look tagged everywhere that flag is displayed.
        committed.podcastName = draft.podcastName.trimmingCharacters(in: .whitespacesAndNewlines)
        committed.episodeTitle = draft.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        committed.chapters = ChapterTableView.sorted(draft.chapters)
        return committed
    }

    /// Reuses the previous chapters' ids wherever an entry is unchanged.
    /// `ChapterParser.parse` mints a fresh `Chapter.id` on every call, and
    /// `reparse()` runs on every keystroke — so without this, every chapter's
    /// identity changes on every character typed. Nothing reads `id` yet, but
    /// the chapter table keys its rows off it, and churning identity there
    /// would reset focus and selection mid-edit.
    nonisolated static func preservingIdentity(of previous: [Chapter], in parsed: [Chapter]) -> [Chapter] {
        // `unclaimed` removes on match so two identical entries cannot both
        // adopt the same id — duplicate ids in a `ForEach` collapse the rows.
        var unclaimed = previous
        return parsed.map { chapter in
            guard let match = unclaimed.firstIndex(where: {
                $0.start == chapter.start && $0.title == chapter.title
            }) else { return chapter }
            let reused = unclaimed.remove(at: match)
            return Chapter(id: reused.id, start: chapter.start, title: chapter.title)
        }
    }

    /// Round-trips stored chapters back into editable text. This must stay the
    /// exact inverse of `ChapterParser.parse` — if the two disagree, reopening
    /// the sheet and pressing Save silently rewrites the user's chapters.
    nonisolated static func text(from chapters: [Chapter]) -> String {
        chapters.map { chapter in
            // Clamp before converting: `Int(TimeInterval)` traps on a value
            // outside Int's range, and nothing stops a caller handing us a
            // nonsense start.
            let clamped = min(max(chapter.start.rounded(), 0), 359_999)
            let total = Int(clamped)
            let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
            let stamp = hours > 0
                ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%02d:%02d", minutes, seconds)
            // One chapter must render as exactly one line. A title carrying a
            // newline would be split back into two lines on the way in, turning
            // one chapter into a chapter plus a malformed line. Unreachable
            // through this sheet, but this function is documented as surviving
            // data it did not produce, and Task 9 will hand it exactly that.
            let title = chapter.title
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .joined(separator: " ")
            return "\(stamp) \(title)"
        }
        .joined(separator: "\n")
    }
}
