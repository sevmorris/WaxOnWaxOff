import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class DeliveryViewModel {
    var files: [FileItem] = []
    var selectedFileIDs: Set<UUID> = []
    var settings: WaxOffSettings {
        didSet { settings.save() }
    }
    var isProcessing = false
    var deliveryPhase: String? = nil
    var alertMessage: String?
    var presetStore = WaxOffPresetStore()
    var log = ProcessingLog()

    private var processingTask: Task<Void, Never>?
    // CRITICAL-3: track analysis/waveform tasks so they can be cancelled on removal
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var analysisInfoTasks: [UUID: Task<Void, Never>] = [:]

    private static let validExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "mp3", "flac", "m4a", "ogg", "opus", "caf", "wma", "aac",
        "mp4", "mov"
    ]

    init() {
        self.settings = WaxOffSettings.load()
    }

    // MARK: - File Management

    func addFiles(_ urls: [URL]) {
        let audioURLs = urls.filter { $0.isFileURL }
        let valid = audioURLs.filter { Self.validExtensions.contains($0.pathExtension.lowercased()) }
        let rejected = audioURLs.count - valid.count

        if rejected > 0 {
            alertMessage = "\(rejected) file\(rejected == 1 ? "" : "s") skipped — unsupported format."
        }

        let newFiles = valid.map { FileItem(url: $0) }
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
        cancelAnalysisTasks(for: Set(files.map { $0.id }))
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

    private func cancelAnalysisTasks(for ids: Set<UUID>) {
        for id in ids {
            analysisTasks[id]?.cancel()
            analysisInfoTasks[id]?.cancel()
            analysisTasks.removeValue(forKey: id)
            analysisInfoTasks.removeValue(forKey: id)
        }
    }

    // MARK: - Processing

    func process() {
        guard !files.isEmpty else { return }

        if let customPath = settings.outputDirectoryPath,
           !FileManager.default.isWritableFile(atPath: customPath) {
            alertMessage = "Output directory is not writable: \(customPath)"
            return
        }

        isProcessing = true
        log.clear()

        let currentSettings = settings

        // Snapshot stats so they survive the status transition
        for i in files.indices {
            if case .ready(let stats) = files[i].status {
                files[i].analysisStats = stats
            }
        }

        processingTask = Task {
            let processor = DeliveryProcessor()

            // CRITICAL-1: snapshot ready file IDs before any await so index mutations
            // during async processing don't corrupt the loop or cause out-of-bounds access.
            let readyFileIDs = files.compactMap { file -> UUID? in
                guard case .ready = file.status else { return nil }
                return file.id
            }

            for fileID in readyFileIDs {
                guard !Task.isCancelled else { break }

                // Re-check: file may have been removed while we awaited the previous one
                guard let file = files.first(where: { $0.id == fileID }),
                      case .ready = file.status else { continue }

                if let idx = files.firstIndex(where: { $0.id == fileID }) {
                    files[idx].status = .processing
                }

                do {
                    let outputURLs = try await processor.process(
                        url: file.url,
                        settings: currentSettings,
                        onPhase: { [weak self] phase in
                            Task { @MainActor [weak self] in
                                self?.deliveryPhase = phase
                            }
                        },
                        onLog: { [weak self] message, level in
                            Task { @MainActor [weak self] in
                                self?.log.append(message, level: level)
                            }
                        }
                    )

                    if let idx = files.firstIndex(where: { $0.id == fileID }),
                       let primaryURL = outputURLs.first {
                        files[idx].status = .processed(outputURL: primaryURL)
                        generateOutputWaveform(id: fileID, url: primaryURL)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if let idx = files.firstIndex(where: { $0.id == fileID }) {
                        files[idx].status = .error(error.localizedDescription)
                    }
                }
            }

            let successCount = files.filter { $0.isProcessed }.count
            await NotificationService.showCompletionNotification(fileCount: successCount)

            isProcessing = false
            deliveryPhase = nil
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - Presets

    func applyPreset(_ preset: WaxOffPreset) {
        settings = preset.settings
        presetStore.selectedPresetID = preset.id
    }

    func saveCurrentAsPreset(name: String) {
        presetStore.savePreset(name: name, settings: settings)
    }

    // MARK: - Private

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

        let task = Task {
            do {
                let stats = try await AudioAnalyzer.analyze(url: file.url)
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
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: file.url)
                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].waveform = waveform
                }
            } catch {
                // HIGH-4: non-critical but log for debugging
                NSLog("WaxOff: waveform generation failed for %@: %@", file.url.lastPathComponent, error.localizedDescription)
            }
        }
    }

    private func generateOutputWaveform(id: UUID, url: URL) {
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: url)
                if let idx = files.firstIndex(where: { $0.id == id }) {
                    files[idx].outputWaveform = waveform
                }
            } catch {
                NSLog("WaxOff: output waveform generation failed for %@: %@", url.lastPathComponent, error.localizedDescription)
            }
        }
    }
}
