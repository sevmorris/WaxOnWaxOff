import Foundation
import Observation
import OSLog
import SwiftUI

// Logger is Sendable and thread-safe — can be captured in @Sendable closures without annotation.
private let fileQueueLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "FileQueue")

/// Shared drag-and-drop file list, analysis, and waveform generation for WaxOn and WaxOff.
@Observable
@MainActor
final class FileQueueCoordinator {
    static let defaultValidExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "mp3", "flac", "m4a", "caf", "aac",
        "mp4", "mov"
    ]

    var files: [FileItem] = []
    var selectedFileIDs: Set<UUID> = []

    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var analysisInfoTasks: [UUID: Task<Void, Never>] = [:]
    private var waveformTasks: [UUID: Task<Void, Never>] = [:]
    private var outputWaveformTasks: [UUID: Task<Void, Never>] = [:]

    let validExtensions: Set<String>
    /// HPF cutoff (Hz) used when estimating noise floor — should match WaxOn processing (80 or 20).
    var noiseFloorHighPassHz: Double = 80

    init(validExtensions: Set<String> = FileQueueCoordinator.defaultValidExtensions) {
        self.validExtensions = validExtensions
    }

    var isAnyFileAnalyzing: Bool {
        files.contains { if case .analyzing = $0.status { return true }; return false }
    }

    func addFiles(
        _ urls: [URL],
        skippedFormatMessage: (Int) -> String,
        beforeCommit: (([URL]) -> Bool)? = nil,
        onCommitted: (() -> Void)? = nil
    ) -> String? {
        let expanded = urls.flatMap { expandFolder($0) }
        let valid = expanded.filter { validExtensions.contains($0.pathExtension.lowercased()) }
        let rejected = expanded.count - valid.count

        var alert: String?
        if rejected > 0 {
            alert = skippedFormatMessage(rejected)
        }

        guard !valid.isEmpty else { return alert }

        if let beforeCommit, !beforeCommit(valid) {
            return alert
        }

        commitFiles(valid)
        onCommitted?()
        return alert
    }

    func commitFiles(_ urls: [URL]) {
        let newFiles = urls.map { FileItem(url: $0) }
        files.append(contentsOf: newFiles)
        let limit = ProcessingConfig.maxConcurrentJobs
        Task { [weak self] in
            guard let self else { return }
            // At most maxConcurrentJobs files start analysis simultaneously. Each
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
            outputWaveformTasks[id]?.cancel()
            analysisTasks.removeValue(forKey: id)
            analysisInfoTasks.removeValue(forKey: id)
            waveformTasks.removeValue(forKey: id)
            outputWaveformTasks.removeValue(forKey: id)
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

    func generateOutputWaveform(id: UUID, url: URL) {
        let task = Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: url)
                if let idx = files.firstIndex(where: { $0.id == id }) {
                    files[idx].outputWaveform = waveform
                }
            } catch {
                fileQueueLogger.debug("Output waveform failed: \(error.localizedDescription, privacy: .public)")
            }
            outputWaveformTasks.removeValue(forKey: id)
        }
        outputWaveformTasks[id] = task
    }

    func analyzeOutputFile(id: UUID, url: URL) {
        Task {
            async let stats = try? AudioAnalyzer.analyze(url: url, noiseFloorHighPassHz: noiseFloorHighPassHz)
            async let info = try? AudioAnalyzer.info(url: url)
            let (s, i) = await (stats, info)
            if let idx = files.firstIndex(where: { $0.id == id }) {
                if let s { files[idx].outputStats = s }
                if let i { files[idx].outputFileInfo = i }
            }
        }
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
