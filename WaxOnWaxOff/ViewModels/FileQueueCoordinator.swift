import Foundation
import Observation
import OSLog
import SwiftUI

private let fileQueueLogger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "FileQueue")

/// Shared drag-and-drop file list, analysis, and waveform generation for WaxOn and WaxOff.
@Observable
@MainActor
final class FileQueueCoordinator {
    static let defaultValidExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "mp3", "flac", "m4a", "ogg", "opus", "caf", "wma", "aac",
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
        for file in newFiles {
            analyzeFile(file)
            generateWaveform(file)
            analyzeFileInfo(file)
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
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
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
