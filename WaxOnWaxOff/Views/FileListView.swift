import SwiftUI
import AppKit

/// A short pre-process channel-conversion hint shown next to the filename
/// (e.g. "MONO→STEREO" in WaxOff, "STEREO→MONO L" in WaxOn).
struct ChannelBadge: Equatable {
    let label: String
    let help: String
}

struct FileListView: View {
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        List(selection: $viewModel.selectedFileIDs) {
            ForEach(viewModel.files) { file in
                FileRowView(
                    file: file,
                    isProcessing: viewModel.isProcessing,
                    channelBadge: channelBadge(for: file)
                )
                    .tag(file.id)
            }
            .onDelete { offsets in
                viewModel.removeFiles(at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveFiles(from: source, to: destination)
            }
        }
        .background(
            Button("") {
                guard !viewModel.selectedFileIDs.isEmpty else { return }
                viewModel.removeSelected()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .hidden()
        )
    }

    /// In WaxOn we surface the inverse of WaxOff's MONO→STEREO badge: whenever
    /// channels are about to be discarded or folded together, the badge is a
    /// heads-up so a stereo room recording isn't silently turned into a
    /// single-channel grab, and a surround stem isn't silently folded to two.
    /// Both output modes are covered — a channel-destructive conversion should
    /// not be announced in one and silent in the other.
    private func channelBadge(for file: FileItem) -> ChannelBadge? {
        guard let info = file.fileInfo else { return nil }

        switch viewModel.settings.outputChannels {
        case .stereo:
            // Stereo output: only a >2-channel source loses anything. A mono
            // source is duplicated into both channels, which discards nothing.
            guard info.channelCount > 2 else { return nil }
            return ChannelBadge(
                label: "MULTI→STEREO",
                help: "\(info.channelCount)-channel source — will be downmixed to stereo via FFmpeg's default matrix (center and surrounds folded in)."
            )

        case .splitLR:
            // Two channels is exactly what this mode is for and loses nothing,
            // so it earns no badge. Anything else falls back to a single mono
            // file, which is worth flagging before the batch runs.
            if info.channelCount == 2 { return nil }
            if info.channelCount == 1 {
                return ChannelBadge(
                    label: "1 FILE",
                    help: "Single-channel source — Split L/R needs two channels, so one mono file will be written."
                )
            }
            return ChannelBadge(
                label: "MULTI→MONO",
                help: "\(info.channelCount)-channel source — Split L/R needs exactly two channels, so this will be downmixed to a single mono file via FFmpeg's default matrix."
            )

        case .mono:
            break
        }

        guard info.channelCount > 1 else { return nil }

        if info.channelCount == 2 {
            let isLeft = viewModel.settings.channel == .left
            let tag = isLeft ? "L" : "R"
            let word = isLeft ? "left" : "right"
            return ChannelBadge(
                label: "STEREO→MONO \(tag)",
                help: "Stereo source — only the \(word) channel will be kept in the mono output. Switch Channels to Stereo in Settings to keep both channels."
            )
        }
        return ChannelBadge(
            label: "MULTI→MONO",
            help: "\(info.channelCount)-channel source — will be downmixed to mono via FFmpeg's default matrix (center and surrounds summed in)."
        )
    }
}

struct FileRowView: View {
    let file: FileItem
    var isProcessing: Bool = false
    var channelBadge: ChannelBadge? = nil
    /// When false (WaxOff), the noise-floor warning triangle is suppressed — the
    /// high-noise-floor heuristic targets raw speech, not finished delivery mixes.
    var applyFloorWarnings: Bool = true
    /// Live processing phase for this row, when the caller tracks one (WaxOff).
    /// Declared last and defaulted to nil so this is purely additive: WaxOn's
    /// call site is unchanged and its rows render exactly as before.
    var phase: String? = nil
    /// Whether a metadata marker may appear on this row. WaxOff only — WaxOn
    /// does not carry per-episode podcast metadata. Declared last and defaulted
    /// to false so this is purely additive: WaxOn's call site is unchanged.
    /// Gating on the flag rather than on `metadata.isEmpty` alone keeps the
    /// badge from silently appearing in WaxOn if it ever gains metadata.
    var showsMetadataBadge: Bool = false

    /// The warning triangle uses the same mode-aware FLOOR classifier as the stats
    /// panel: it fires only at a flagged severity, and never in WaxOff (where a mix may
    /// legitimately carry continuous low-level content — music beds, room tone).
    private var showsNoiseFloorWarning: Bool {
        guard let nf = file.stats?.noiseFloor else { return false }
        return FileInfoStatsView.floorSeverity(dBFS: nf, applyWarnings: applyFloorWarnings) != .normal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(file.url.lastPathComponent)
                    .font(.body)

                if let badge = channelBadge, !file.isProcessed {
                    Text(badge.label)
                        .font(AppFont.sectionLabel)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help(badge.help)
                }

                // Deliberately NOT gated on `!file.isProcessed`, which is where
                // the channel badge above does disappear. The analogy does not
                // hold: that badge forecasts a conversion that has not happened
                // yet and is rightly moot once it has. This one records
                // something already written into the delivered file — a fact,
                // not a forecast. A finished batch is exactly when someone wants
                // to scan the list and confirm every episode was tagged, so
                // hiding it at completion would remove the badge at the one
                // moment `metadataSummary` is most worth reading.
                if showsMetadataBadge, !file.metadata.isEmpty {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help(Self.metadataSummary(file.metadata))
                        .accessibilityLabel("Has podcast metadata")
                        // `.help` becomes VoiceOver's *hint*, which is spoken
                        // only when "Speak hints automatically" is enabled and
                        // then only after a pause — so on hover a sighted user
                        // would get the podcast, title, artwork and chapter
                        // count while a VoiceOver user got "has podcast
                        // metadata" and nothing else. A value is always
                        // announced with the element.
                        .accessibilityValue(Self.metadataSummary(file.metadata))
                }

                if showsNoiseFloorWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.meterWarning)
                        .font(.caption)
                        .help("High noise floor — loudness normalization may be less accurate. Enable Loudness Norm so the automatic NR analysis runs.")
                }

                if file.isProcessed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Complete")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if !file.outputURLs.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(file.outputURLs)
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
            }

            statusText

            if case .processing = file.status {
                ProgressView(value: nil as Double?)
                    .progressViewStyle(.linear)
                    .tint(.brandAccent)
            } else if isProcessing, case .ready = file.status {
                ProgressView(value: 0.0, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .opacity(0.35)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch file.status {
        case .pending:
            Text("Waiting...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .analyzing:
            Text("Calculating stats...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .processing:
            // The phase, when the caller supplies one, says which stage this
            // file is actually in; "Processing..." is the fallback for a row
            // that has not emitted a phase yet, and for WaxOn.
            Text(phase ?? "Processing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready(let stats):
            Text("RMS \(stats.rms, specifier: "%.1f") dBFS \u{2022} Peak \(stats.peak, specifier: "%.1f") dBFS")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .processed(let outputURLs):
            Text("\(outputURLs.count > 1 ? "Outputs" : "Output"): \(outputURLs.map(\.lastPathComponent).joined(separator: " \u{2022} "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .error(let message):
            Text("Error: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Tooltip listing what this file carries, so a batch shows at a glance
    /// which episodes are tagged without opening each sheet. One field per
    /// line: AppKit tooltips wrap on newlines, and the alternative separators
    /// (" • ", ", ") run together with titles that contain the same
    /// punctuation.
    ///
    /// `nonisolated` so the tests can call it off the main actor, matching
    /// `MetadataSheet`'s static helpers.
    ///
    /// The newline separator is the one thing here that has never been looked
    /// at: no other `.help()` string in this codebase spans multiple lines, and
    /// the machine this was written on could not grant Screen Recording
    /// permission, so the rendered tooltip was never seen. AppKit tooltips are
    /// documented to honor newlines; if this one instead renders as a single
    /// run-together line, the fix is entirely local to this function and its
    /// tests.
    nonisolated static func metadataSummary(_ metadata: EpisodeMetadata) -> String {
        var parts: [String] = []
        if !metadata.podcastName.isEmpty { parts.append("Podcast: \(metadata.podcastName)") }
        if !metadata.episodeTitle.isEmpty { parts.append("Title: \(metadata.episodeTitle)") }
        if metadata.artworkURL != nil { parts.append("Artwork set") }
        if !metadata.chapters.isEmpty {
            // The supplied wording said "\(count) chapters" unconditionally,
            // which renders "1 chapters". Matches the sheet's own phrasing.
            let count = metadata.chapters.count
            parts.append("\(count) chapter\(count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No metadata" : parts.joined(separator: "\n")
    }
}
