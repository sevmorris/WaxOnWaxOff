import SwiftUI

/// The tabular half of the chapter editor: one editable row per chapter,
/// sitting under `MetadataSheet`'s paste box and editing the same
/// `[Chapter]`.
///
/// Three decisions shape everything below.
///
/// **One timestamp grammar.** `seconds(fromStamp:duration:)` does not parse
/// anything itself — it hands the stamp to `ChapterParser` with a sentinel
/// title. `stamp(for:)` likewise renders through `MetadataSheet.text(from:)`
/// and takes the part before the first space, which is exactly where the
/// parser splits. So the two surfaces cannot drift into accepting or
/// producing different syntax; there is one definition of each direction.
///
/// **The model is only ever written in normal form.** A chapter written from
/// this table always has a whole-second start, a title with no newlines and
/// no leading or trailing whitespace, and a position that keeps the array
/// sorted. That is precisely the condition under which
/// `ChapterParser.parse(MetadataSheet.text(from: c)) == c`, which is what
/// makes the sheet's two-way sync a one-step fixpoint instead of a loop.
///
/// **The fields display drafts, never the model, while they are being
/// edited.** `timeDrafts` and `titleDrafts` hold exactly what the user typed.
/// Nothing in this view or in `MetadataSheet` ever writes back into a field,
/// so the round trip above cannot rewrite text under the cursor, and a
/// half-typed or unparsable timestamp stays on screen instead of being
/// reverted to the old value.
struct ChapterTableView: View {
    @Binding var chapters: [Chapter]
    /// nil while the file is still being analyzed. Matches `MetadataSheet`:
    /// an unknown length means no range check rather than rejecting
    /// everything.
    let duration: TimeInterval?
    /// Reported upward so the sheet can block Save. An unparsable timestamp
    /// leaves the model holding the row's *previous* start, so saving while
    /// one is on screen would commit a value the user has visibly replaced.
    @Binding var timeError: String?

    /// Literal field contents for rows the user has touched. An entry present
    /// here wins over the model, which is what stops a regenerated round trip
    /// from rewriting the field mid-keystroke.
    @State private var timeDrafts: [UUID: String] = [:]
    @State private var titleDrafts: [UUID: String] = [:]
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case time(UUID)
        case title(UUID)
    }

    /// Parsing with an unbounded length while the duration is unknown, for the
    /// same reason `MetadataSheet.reparse()` does: zero would trip the
    /// parser's `start < duration` guard on every row.
    private var limit: TimeInterval { duration ?? .greatestFiniteMagnitude }

    var body: some View {
        // Hoisted: the Add button needs this for both its enabled state and its
        // tooltip, and it scans the whole array.
        let roomForAnother = Self.nextStart(after: chapters, duration: duration)

        return VStack(alignment: .leading, spacing: 4) {
            if chapters.isEmpty {
                Text("No chapters yet. Paste them above, or add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                headerRow
                ForEach(chapters) { chapter in
                    row(for: chapter)
                }
            }

            if let timeError {
                Label(timeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.meterCritical)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Button {
                addChapter()
            } label: {
                Label("Add Chapter", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(roomForAnother == nil)
            .help(roomForAnother == nil
                  ? "There is no room for another chapter before the end of the audio."
                  : "Add a chapter one minute after the last one.")
            .padding(.top, 4)
        }
        // Drafts are released on blur, not on every keystroke: releasing while
        // the field is focused would snap "1:30" to "01:30" as it is typed.
        .onChange(of: focused) { previous, _ in releaseDraft(for: previous) }
        // A paste-box edit can retitle or delete a row, which changes or
        // removes its id. Drafts keyed to ids that no longer exist would
        // otherwise sit there forever holding Save disabled.
        .onChange(of: chapters) { _, updated in pruneDrafts(keeping: updated) }
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("TIME")
                .frame(width: 90, alignment: .leading)
            Text("TITLE")
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 16, height: 1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .kerning(0.4)
        // The two fields in each row carry their own labels; VoiceOver reading
        // a bare "TIME TITLE" row before them is noise.
        .accessibilityHidden(true)
    }

    private func row(for chapter: Chapter) -> some View {
        let invalid = isInvalid(chapter.id)
        return HStack(spacing: 8) {
            TextField("", text: timeBinding(for: chapter))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
                .focused($focused, equals: .time(chapter.id))
                // Return commits the field rather than firing the sheet's
                // default button. Without this, pressing Return after typing a
                // timestamp saves and dismisses the whole sheet.
                .onSubmit { focused = nil }
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.meterCritical.opacity(invalid ? 0.8 : 0), lineWidth: 1)
                )
                .accessibilityLabel("Chapter start time")
                .accessibilityHint("Minutes colon seconds, or hours colon minutes colon seconds.")

            TextField("", text: titleBinding(for: chapter), prompt: Text("Chapter title"))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .title(chapter.id))
                .onSubmit { focused = nil }
                .accessibilityLabel("Chapter title")

            Button {
                remove(chapter.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this chapter")
            // Named, because a bare "Remove chapter, button" reads identically
            // on every row. The two text fields differentiate themselves —
            // VoiceOver appends their value — but an image button has none, so
            // without this a screen-reader user in a multi-chapter list cannot
            // tell which row's delete they are about to press.
            .accessibilityLabel(chapter.title.isEmpty
                ? "Remove chapter at \(Self.stamp(for: chapter.start))"
                : "Remove chapter, \(chapter.title)")
        }
    }

    // MARK: - Field bindings

    private func timeBinding(for chapter: Chapter) -> Binding<String> {
        Binding(
            get: { timeDrafts[chapter.id] ?? Self.stamp(for: chapter.start) },
            set: { typed in
                timeDrafts[chapter.id] = typed
                // Committed on every keystroke that parses rather than on blur.
                // Blur-only commits lose the edit outright when the user types
                // a time and clicks Save, because a macOS button click does not
                // reliably end editing in the field. An in-progress or invalid
                // stamp simply does not commit; the draft above keeps the
                // keystrokes on screen and `timeError` blocks Save until it is
                // either fixed or abandoned.
                if let start = Self.seconds(fromStamp: typed, duration: limit) {
                    chapters = Self.applying(start: start, toChapterWith: chapter.id, in: chapters)
                }
                refreshTimeError()
            }
        )
    }

    private func titleBinding(for chapter: Chapter) -> Binding<String> {
        Binding(
            get: { titleDrafts[chapter.id] ?? chapter.title },
            set: { typed in
                titleDrafts[chapter.id] = typed
                // Normalized on the way in, raw on the way out. Storing the raw
                // text would break the round-trip fixpoint — the parser trims,
                // so a trailing space would come back as a different title,
                // change the chapter's identity, and tear the row down while
                // the user is still typing in it.
                chapters = Self.applying(
                    title: Self.normalizedTitle(typed),
                    toChapterWith: chapter.id,
                    in: chapters
                )
            }
        )
    }

    // MARK: - Draft lifecycle

    private func releaseDraft(for field: Field?) {
        guard let field else { return }
        switch field {
        case .time(let id):
            // An unparsable draft is deliberately kept. Dropping it here would
            // replace what the user typed with the old start, silently
            // discarding the edit and hiding the reason Save is disabled.
            if let draft = timeDrafts[id], Self.seconds(fromStamp: draft, duration: limit) != nil {
                timeDrafts.removeValue(forKey: id)
            }
        case .title(let id):
            titleDrafts.removeValue(forKey: id)
        }
        refreshTimeError()
    }

    private func pruneDrafts(keeping updated: [Chapter]) {
        let live = Set(updated.map(\.id))
        let times = Self.pruned(timeDrafts, keeping: live)
        let titles = Self.pruned(titleDrafts, keeping: live)
        // Guarded so this cannot bounce state on every unrelated change.
        guard times.count != timeDrafts.count || titles.count != titleDrafts.count else { return }
        timeDrafts = times
        titleDrafts = titles
        refreshTimeError()
    }

    private func isInvalid(_ id: UUID) -> Bool {
        guard let draft = timeDrafts[id] else { return false }
        return Self.seconds(fromStamp: draft, duration: limit) == nil
    }

    private func refreshTimeError() {
        let live = Set(chapters.map(\.id))
        let bad = timeDrafts.filter { id, draft in
            live.contains(id) && Self.seconds(fromStamp: draft, duration: limit) == nil
        }.count
        let message = Self.timeErrorMessage(invalidCount: bad, hasDuration: duration != nil)
        // Compared before writing: this runs from `onChange`, and rewriting an
        // identical value would invalidate the sheet on every keystroke.
        if timeError != message { timeError = message }
    }

    // MARK: - Row commands

    private func addChapter() {
        guard let start = Self.nextStart(after: chapters, duration: duration) else { return }
        // A placeholder title rather than an empty one on purpose: an empty
        // title makes the whole list unparsable the instant the row appears,
        // which reads as the Add button being broken.
        let chapter = Chapter(start: start, title: "New chapter")
        chapters = Self.sorted(chapters + [chapter])
        focused = .title(chapter.id)
    }

    private func remove(_ id: UUID) {
        timeDrafts.removeValue(forKey: id)
        titleDrafts.removeValue(forKey: id)
        if focused == .time(id) || focused == .title(id) { focused = nil }
        chapters = Self.removing(id: id, from: chapters)
        refreshTimeError()
    }

    // MARK: - Pure helpers

    /// Seconds from a single timestamp, or nil if it is not one.
    ///
    /// Delegates to `ChapterParser` with a sentinel title so this surface
    /// accepts exactly the syntax the paste box accepts — including the
    /// duration range check — without a second grammar to keep in step.
    nonisolated static func seconds(fromStamp raw: String, duration: TimeInterval) -> TimeInterval? {
        let stamp = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Interior whitespace has to be rejected here rather than left to the
        // parser: `parse("1:30 extra x")` splits at the first space and reads
        // "1:30" as the time with "extra x" as the title, so "1:30 extra"
        // would be accepted as a timestamp.
        guard !stamp.isEmpty,
              !stamp.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
        guard case .success(let parsed) = ChapterParser.parse("\(stamp) x", duration: duration),
              let first = parsed.first else { return nil }
        return first.start
    }

    /// The canonical rendering of a start, identical to the timestamp
    /// `MetadataSheet.text(from:)` writes for the same chapter. Rendered
    /// through that function and split where the parser splits, so the table
    /// and the paste box can never show a start two different ways.
    nonisolated static func stamp(for start: TimeInterval) -> String {
        let line = MetadataSheet.text(from: [Chapter(start: start, title: "•")])
        guard let space = line.firstIndex(of: " ") else { return line }
        return String(line[line.startIndex..<space])
    }

    /// The form a title has to be stored in for `text(from:)` → `parse` to
    /// return it unchanged: newlines flattened exactly as `text(from:)`
    /// flattens them, then trimmed exactly as the parser trims.
    nonisolated static func normalizedTitle(_ raw: String) -> String {
        raw
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sorted by start. This relies on the sort being *stable*, which Swift
    /// guarantees for `sorted(by:)` (SE-0372).
    ///
    /// Stability is load-bearing here rather than cosmetic. A timestamp edit
    /// passes through equal starts on its way somewhere else — retyping
    /// `02:00` as `01:00` momentarily matches whatever already sits at one
    /// minute — and an unstable sort would swap those two rows for that one
    /// keystroke. Rows are keyed by `id` and each row's field contents are
    /// keyed to that id, so a swap would hand each row the other's text
    /// mid-edit.
    nonisolated static func sorted(_ chapters: [Chapter]) -> [Chapter] {
        chapters.sorted { $0.start < $1.start }
    }

    /// Moves one chapter to a new start. Mutates in place and re-sorts, so a
    /// row that changes position carries its `id` — and therefore its drafts
    /// and its focus — with it rather than swapping contents with a neighbour.
    nonisolated static func applying(
        start: TimeInterval,
        toChapterWith id: UUID,
        in chapters: [Chapter]
    ) -> [Chapter] {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return chapters }
        var updated = chapters
        updated[index].start = start
        return sorted(updated)
    }

    /// No re-sort: a title cannot change the ordering, and re-sorting here
    /// would reorder equal-start rows for no reason.
    nonisolated static func applying(
        title: String,
        toChapterWith id: UUID,
        in chapters: [Chapter]
    ) -> [Chapter] {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return chapters }
        var updated = chapters
        updated[index].title = title
        return updated
    }

    nonisolated static func removing(id: UUID, from chapters: [Chapter]) -> [Chapter] {
        chapters.filter { $0.id != id }
    }

    /// Drafts belonging to chapters that no longer exist. Rows can vanish two
    /// ways — an explicit remove, or a paste-box edit replacing the array
    /// wholesale — and a draft left behind would reappear if a later chapter
    /// happened to be minted with the same id. A stale *time* draft would also
    /// hold `timeError` set, disabling Save with no visible row to fix.
    nonisolated static func pruned(_ drafts: [UUID: String], keeping live: Set<UUID>) -> [UUID: String] {
        drafts.filter { live.contains($0.key) }
    }

    /// Where an added chapter goes, or nil when there is nowhere left to put
    /// one. A minute after the last chapter normally; one second after it when
    /// that would land at or past the end of the audio; nil when even that
    /// does not fit, which is what disables the Add button rather than letting
    /// it mint a row that immediately fails to parse.
    nonisolated static func nextStart(after chapters: [Chapter], duration: TimeInterval?) -> TimeInterval? {
        // 359_999 is the largest start `MetadataSheet.text(from:)` renders
        // without clamping; going past it would break the round trip.
        let limit = min(duration ?? .greatestFiniteMagnitude, 360_000)
        guard let last = chapters.map(\.start).max() else {
            return limit > 0 ? 0 : nil
        }
        let base = min(max(last.rounded(), 0), 359_999)
        for candidate in [base + 60, base + 1] where candidate < limit {
            return candidate
        }
        return nil
    }

    nonisolated static func timeErrorMessage(invalidCount: Int, hasDuration: Bool) -> String? {
        guard invalidCount > 0 else { return nil }
        let range = hasDuration ? ", within the file's length" : ""
        if invalidCount == 1 {
            return "One chapter time is not a valid timestamp. Use MM:SS or HH:MM:SS\(range)."
        }
        return "\(invalidCount) chapter times are not valid timestamps. Use MM:SS or HH:MM:SS\(range)."
    }
}
