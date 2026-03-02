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
    var presetStore = PresetStore()

    private var processingTask: Task<Void, Never>?

    private static let validExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "flac", "m4a", "ogg", "opus", "caf", "wma", "aac"
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
        files.removeAll { selectedFileIDs.contains($0.id) }
        selectedFileIDs.removeAll()
    }

    func clearAll() {
        files.removeAll()
        selectedFileIDs.removeAll()
    }

    func removeFiles(at offsets: IndexSet) {
        let deletedIDs = Set(offsets.map { files[$0].id })
        files.remove(atOffsets: offsets)
        selectedFileIDs.subtract(deletedIDs)
    }

    func moveFiles(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
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

        let currentSettings = settings

        // Snapshot stats so they survive the status transition
        for i in files.indices {
            if case .ready(let stats) = files[i].status {
                files[i].analysisStats = stats
            }
        }

        processingTask = Task {
            let processor = DeliveryProcessor()

            for i in files.indices {
                guard !Task.isCancelled else { break }

                let file = files[i]
                guard case .ready = file.status else { continue }

                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].status = .processing
                }

                do {
                    let outputURLs = try await processor.process(
                        url: file.url,
                        settings: currentSettings
                    ) { [weak self] phase in
                        Task { @MainActor [weak self] in
                            self?.deliveryPhase = phase
                        }
                    }

                    if let idx = files.firstIndex(where: { $0.id == file.id }),
                       let primaryURL = outputURLs.first {
                        files[idx].status = .processed(outputURL: primaryURL)
                        generateOutputWaveform(id: file.id, url: primaryURL)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if let idx = files.firstIndex(where: { $0.id == file.id }) {
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

    func applyPreset(_ preset: Preset) {
        settings = preset.settings
        presetStore.selectedPresetID = preset.id
    }

    func saveCurrentAsPreset(name: String) {
        presetStore.savePreset(name: name, settings: settings)
    }

    // MARK: - Private

    private func analyzeFileInfo(_ file: FileItem) {
        Task {
            if let info = try? await AudioAnalyzer.info(url: file.url),
               let idx = files.firstIndex(where: { $0.id == file.id }) {
                files[idx].fileInfo = info
            }
        }
    }

    private func analyzeFile(_ file: FileItem) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index].status = .analyzing

        Task {
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
        }
    }

    private func generateWaveform(_ file: FileItem) {
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: file.url)
                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].waveform = waveform
                }
            } catch {}
        }
    }

    private func generateOutputWaveform(id: UUID, url: URL) {
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: url)
                if let idx = files.firstIndex(where: { $0.id == id }) {
                    files[idx].outputWaveform = waveform
                }
            } catch {}
        }
    }
}
