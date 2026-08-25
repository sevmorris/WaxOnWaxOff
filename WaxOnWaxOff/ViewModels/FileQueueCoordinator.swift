import Foundation
import Observation
import OSLog
import SwiftUI

// Logger is Sendable and thread-safe — can be captured in @Sendable closures without annotation.
nonisolated private let fileQueueLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "FileQueue")

/// Shared drag-and-drop file list, analysis, and waveform generation for WaxOn and WaxOff.
@Observable
@MainActor
final class FileQueueCoordinator {
    nonisolated static let defaultValidExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "mp3", "flac", "m4a", "caf", "aac",
        "mp4", "mov"
    ]

    var files: [FileItem] = []
    var selectedFileIDs: Set<UUID> = []

    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var analysisInfoTasks: [UUID: Task<Void, Never>] = [:]
    private var waveformTasks: [UUID: Task<Void, Never>] = [:]
    /// Output analyses in flight, per row. A row can have one per output —
    /// they're started lazily as the user switches between them and left in
    /// place until the row is re-rendered or removed, so the array is bounded
    /// by the job's output count (two at most today).
    private var outputAnalysisTasks: [UUID: [Task<Void, Never>]] = [:]

    let validExtensions: Set<String>
    /// HPF cutoff (Hz) used when estimating noise floor — should match WaxOn processing (80 or 20).
    var noiseFloorHighPassHz: Double = 80

    init(validExtensions: Set<String> = FileQueueCoordinator.defaultValidExtensions) {
        self.validExtensions = validExtensions
    }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. this is owned by the WaxOn/WaxOff view models and released with
    // them when the window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    var isAnyFileAnalyzing: Bool {
        files.contains { if case .analyzing = $0.status { return true }; return false }
    }

    /// What `addFiles` has to say about the files it did not take, and how
    /// much of the user's attention that is worth.
    ///
    /// The two cases differ in whether the add did anything. Dropping a folder
    /// that happens to hold a `readme.txt` is the ordinary case rather than a
    /// mistake — the audio all loaded, and a modal in front of that interrupts
    /// a success. Skipping *every* file is the other story: the list looks
    /// exactly as it did before, so without an alert the add appears to have
    /// silently done nothing.
    enum SkipReport {
        /// Nothing loaded. Worth interrupting for.
        case alert(String)
        /// Some files loaded, some were skipped. Belongs on the Console.
        case notice(String)
    }

    func addFiles(
        _ urls: [URL],
        skippedFormatMessage: (Int) -> String,
        beforeCommit: (([URL]) -> Bool)? = nil,
        onCommitted: (() -> Void)? = nil
    ) -> SkipReport? {
        let expanded = urls.flatMap { expandFolder($0) }
        let valid = expanded.filter { validExtensions.contains($0.pathExtension.lowercased()) }
        let rejected = expanded.count - valid.count

        var report: SkipReport?
        if rejected > 0 {
            // `expandFolder` enumerates with `.skipsHiddenFiles`, so `.DS_Store`
            // and its kind never reach this count — everything reported here is
            // a file the user can actually see in the folder they added.
            let message = skippedFormatMessage(rejected)
            report = valid.isEmpty ? .alert(message) : .notice(message)
        }

        guard !valid.isEmpty else { return report }

        if let beforeCommit, !beforeCommit(valid) {
            return report
        }

        commitFiles(valid)
        onCommitted?()
        return report
    }

    func commitFiles(_ urls: [URL]) {
        let newFiles = urls.map { FileItem(url: $0) }
        files.append(contentsOf: newFiles)
        let limit = ProcessingConfig.analysisConcurrency
        Task { [weak self] in
            guard let self else { return }
            // At most analysisConcurrency files start analysis simultaneously. Each
            // slot calls the three per-file methods and then holds until the
            // analysis Task finishes, so ffprobe/AVFoundation concurrency is
            // actually bounded rather than just task-spawning being bounded.
            // Waveform and fileInfo tasks continue beyond the gate; they are
            // lighter than analysis (no ffprobe subprocess). Task dicts are still
            // populated by the per-file methods for individual cancellation.
            _ = try? await runBoundedConcurrent(inputs: newFiles, limit: limit) { [weak self] file in
                guard let self else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.analyzeFile(file)
                    self.generateWaveform(file)
                    self.analyzeFileInfo(file)
                }
                // Await the analysis task to hold the slot. If the file was removed
                // while we waited, cancelAnalysisTasks cleared the dict entry and we
                // skip the await — the slot releases and the next file starts.
                if let task = await MainActor.run(body: { [weak self] in self?.analysisTasks[file.id] }) {
                    _ = await task.value
                }
            }
        }
    }

    func removeSelected() {
        cancelAnalysisTasks(for: selectedFileIDs)
        files.removeAll { selectedFileIDs.contains($0.id) }
        selectedFileIDs.removeAll()
    }

    func clearAll() {
        cancelAnalysisTasks(for: Set(files.map(\.id)))
        files.removeAll()
        selectedFileIDs.removeAll()
    }

    func removeFiles(at offsets: IndexSet) {
        let deletedIDs = Set(offsets.map { files[$0].id })
        cancelAnalysisTasks(for: deletedIDs)
        files.remove(atOffsets: offsets)
        selectedFileIDs.subtract(deletedIDs)
    }

    func moveFiles(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
    }

    func cancelAnalysisTasks(for ids: Set<UUID>) {
        for id in ids {
            analysisTasks[id]?.cancel()
            analysisInfoTasks[id]?.cancel()
            waveformTasks[id]?.cancel()
            outputAnalysisTasks[id]?.forEach { $0.cancel() }
            analysisTasks.removeValue(forKey: id)
            analysisInfoTasks.removeValue(forKey: id)
            waveformTasks.removeValue(forKey: id)
            outputAnalysisTasks.removeValue(forKey: id)
        }
    }

    func snapshotReadyStats() {
        for i in files.indices {
            if case .ready(let stats) = files[i].status {
                files[i].analysisStats = stats
            }
        }
    }

    func restoreProcessingRows(interruptedMessage: String = "Processing interrupted") {
        for i in files.indices {
            guard case .processing = files[i].status else { continue }
            if let stats = files[i].analysisStats {
                files[i].status = .ready(stats)
            } else {
                // Defensive: a row that reached `.processing` should always
                // have stats snapshotted (the Process button is disabled while
                // `isAnyFileAnalyzing`). This branch only fires if a bug lets a
                // row slip through pre-analysis — keep the visible error so
                // it's noticed in QA rather than silently dropping to .pending.
                files[i].status = .error(interruptedMessage)
            }
        }
    }

    func restoreProcessingRowsAfterCancel() {
        for i in files.indices {
            guard case .processing = files[i].status else { continue }
            if let stats = files[i].analysisStats {
                files[i].status = .ready(stats)
            } else {
                files[i].status = .pending
            }
        }
    }

    /// Post-render refresh: attaches the job's outputs to the row and measures
    /// the one the detail pane will show. Only that first output is analyzed
    /// here — the others are measured on demand in `selectOutput` so a split
    /// render doesn't pay for a decode the user may never look at.
    func attachOutputs(id: UUID, urls: [URL]) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        outputAnalysisTasks[id]?.forEach { $0.cancel() }
        outputAnalysisTasks.removeValue(forKey: id)
        let labels = OutputFile.labels(for: urls)
        files[idx].outputs = zip(urls, labels).map { OutputFile(url: $0, label: $1) }
        files[idx].selectedOutputIndex = 0
        analyzeOutput(id: id, index: 0)
    }

    /// Shows a different output of a completed row, measuring it first if this
    /// is the first time it's been looked at.
    func selectOutput(id: UUID, index: Int) {
        guard let idx = files.firstIndex(where: { $0.id == id }),
              files[idx].outputs.indices.contains(index) else { return }
        files[idx].selectedOutputIndex = index
        analyzeOutput(id: id, index: index)
    }

    /// Stats, waveform, and file info for one rendered output. Stats and
    /// waveform share a single decode of the file (previously two separate
    /// full streams); file info is a header-only read.
    private func analyzeOutput(id: UUID, index: Int) {
        guard let idx = files.firstIndex(where: { $0.id == id }),
              files[idx].outputs.indices.contains(index),
              files[idx].outputs[index].stats == nil else { return }
        let url = files[idx].outputs[index].url
        let hpf = noiseFloorHighPassHz
        let task = Task {
            async let combined = try? AudioAnalyzer.analyzeWithWaveform(url: url, noiseFloorHighPassHz: hpf)
            async let info = try? AudioAnalyzer.info(url: url)
            let (c, i) = await (combined, info)
            if c == nil {
                fileQueueLogger.debug("Output analysis failed: \(url.lastPathComponent, privacy: .public)")
            }
            // Re-find the row and the output: the queue can be reordered, and
            // the row re-rendered, while this decode is in flight.
            guard let idx = files.firstIndex(where: { $0.id == id }),
                  let out = files[idx].outputs.firstIndex(where: { $0.url == url }) else { return }
            if let c {
                files[idx].outputs[out].stats = c.stats
                files[idx].outputs[out].waveform = c.waveform
            }
            if let i { files[idx].outputs[out].fileInfo = i }
        }
        outputAnalysisTasks[id, default: []].append(task)
    }

    private func expandFolder(_ url: URL) -> [URL] {
        guard url.hasDirectoryPath else { return [url] }

        // Resolve the root path once for ancestor-cycle detection below.
        // resolvingSymlinksInPath() never throws — it returns the original URL on failure.
        let rootRealPath = url.resolvingSymlinksInPath().path

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let maxDepth = 8   // sufficient for any real podcast asset folder
        var results: [URL] = []

        for case let fileURL as URL in enumerator {
            // Hard depth cap — enumerator.level is 1-based (root's direct children = 1).
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])

            if rv?.isSymbolicLink == true {
                // Resolve the symlink. resolvingSymlinksInPath() returns the original
                // URL unchanged when it cannot be resolved — no failure to guard against.
                let resolved = fileURL.resolvingSymlinksInPath()
                // Skip if the resolved target is an ancestor of (or equal to) the
                // enumeration root — following it would create an infinite loop.
                let rp = resolved.path
                if rootRealPath.hasPrefix(rp + "/") || rp == rootRealPath {
                    enumerator.skipDescendants()
                    continue
                }
            }

            if rv?.isRegularFile == true {
                results.append(fileURL)
            }
        }

        return results
    }

    private func analyzeFileInfo(_ file: FileItem) {
        let task = Task {
            if let info = try? await AudioAnalyzer.info(url: file.url),
               let idx = files.firstIndex(where: { $0.id == file.id }) {
                files[idx].fileInfo = info
            }
            analysisInfoTasks.removeValue(forKey: file.id)
        }
        analysisInfoTasks[file.id] = task
    }

    private func analyzeFile(_ file: FileItem) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index].status = .analyzing
        let hpf = noiseFloorHighPassHz

        let task = Task {
            do {
                let tools = try await FFmpegManager.shared.ensureTools()
                guard await AudioStreamProbe.hasAudioStream(
                    ffprobe: tools.ffprobe,
                    url: file.url,
                    onLog: { detail in
                        fileQueueLogger.debug("\(detail, privacy: .public)")
                    }
                ) else {
                    if let idx = files.firstIndex(where: { $0.id == file.id }) {
                        files[idx].status = .error("No audio stream found — file may be misnamed or unsupported.")
                    }
                    analysisTasks.removeValue(forKey: file.id)
                    return
                }
                let stats = try await AudioAnalyzer.analyze(url: file.url, noiseFloorHighPassHz: hpf)
                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].status = .ready(stats)
                }
            } catch {
                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].status = .error(error.localizedDescription)
                }
            }
            analysisTasks.removeValue(forKey: file.id)
        }
        analysisTasks[file.id] = task
    }

    private func generateWaveform(_ file: FileItem) {
        let task = Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: file.url)
                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].waveform = waveform
                }
            } catch {
                fileQueueLogger.debug("Waveform failed: \(error.localizedDescription, privacy: .public)")
            }
            waveformTasks.removeValue(forKey: file.id)
        }
        waveformTasks[file.id] = task
    }
}
