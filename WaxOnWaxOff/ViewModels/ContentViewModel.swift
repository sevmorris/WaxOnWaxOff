import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class ContentViewModel {
    var files: [FileItem] = []
    var selectedFileIDs: Set<UUID> = []
    var settings: WaxOnSettings {
        didSet { settings.save() }
    }
    var isProcessing = false
    var mixPhase: String? = nil
    var alertMessage: String?
    var presetStore = WaxOnPresetStore()
    var log = ProcessingLog()
    private var processingTask: Task<Void, Never>?

    private static let validExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "flac", "m4a", "ogg", "opus", "caf", "wma", "aac",
        "mp4", "mov"
    ]

    init() {
        self.settings = WaxOnSettings.load()
    }

    func addFiles(_ urls: [URL]) {
        let audioURLs = urls.filter { $0.isFileURL }
        let valid = audioURLs.filter { Self.validExtensions.contains($0.pathExtension.lowercased()) }
        let rejected = audioURLs.count - valid.count

        if rejected > 0 {
            alertMessage = "\(rejected) file\(rejected == 1 ? "" : "s") skipped — unsupported format. Supported: wav, aif, aiff, mp3, flac, m4a, ogg, opus, caf, wma, aac, mp4, mov."
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

    // MARK: - Presets

    func applyPreset(_ preset: WaxOnPreset) {
        settings = preset.settings
        presetStore.selectedPresetID = preset.id
    }

    func saveCurrentAsPreset(name: String) {
        presetStore.savePreset(name: name, settings: settings)
    }

    func process() {
        guard !files.isEmpty else { return }

        // Validate custom output directory upfront before any processing starts
        if let customPath = settings.outputDirectoryPath,
           !FileManager.default.isWritableFile(atPath: customPath) {
            alertMessage = "Output directory is not writable: \(customPath)"
            return
        }

        isProcessing = true
        log.clear()

        let currentSettings = settings
        let inputs = files.map { JobInput(id: $0.id, url: $0.url) }

        // Snapshot stats so they survive the status transition
        for i in files.indices {
            if case .ready(let stats) = files[i].status {
                files[i].analysisStats = stats
            }
        }

        processingTask = Task {
            do {
                let processor = AudioProcessor(settings: currentSettings,
                    onFileStarted: { [weak self] id in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            guard let index = self.files.firstIndex(where: { $0.id == id }),
                                  !self.files[index].isProcessed else { return }
                            self.files[index].status = .processing
                        }
                    },
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    })
                let results = try await processor.run(inputs: inputs)

                for result in results {
                    if let id = result.id,
                       let index = files.firstIndex(where: { $0.id == id }) {
                        files[index].status = .processed(outputURL: result.output)
                    }
                }

                // Generate output waveforms
                for result in results {
                    if let id = result.id {
                        generateOutputWaveform(id: id, url: result.output)
                    }
                }

                await NotificationService.showCompletionNotification(fileCount: results.count)
            } catch is CancellationError {
                // User cancelled — no alert needed
            } catch {
                alertMessage = error.localizedDescription
            }

            isProcessing = false
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        mixPhase = nil
        for i in files.indices {
            if case .processing = files[i].status {
                if let stats = files[i].analysisStats {
                    files[i].status = .ready(stats)
                } else {
                    files[i].status = .pending
                }
            }
        }
    }

    func mixSelected() {
        guard selectedFileIDs.count >= 2 else { return }
        let selectedURLs = files.filter { selectedFileIDs.contains($0.id) }.map { $0.url }
        isProcessing = true
        log.clear()
        processingTask = Task {
            do {
                let processor = AudioProcessor(settings: settings,
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    })
                let result = try await processor.mixAndProcess(inputs: selectedURLs) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        self?.mixPhase = phase
                    }
                }
                let newItem = FileItem(url: result.output)
                files.append(newItem)
                if let idx = files.firstIndex(where: { $0.id == newItem.id }) {
                    files[idx].status = .processed(outputURL: result.output)
                }
                generateOutputWaveform(id: newItem.id, url: result.output)
                await NotificationService.showCompletionNotification(fileCount: 1)
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
            }
            isProcessing = false
            mixPhase = nil
            processingTask = nil
        }
    }

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
                if let currentIndex = files.firstIndex(where: { $0.id == file.id }) {
                    files[currentIndex].status = .ready(stats)
                }
            } catch {
                if let currentIndex = files.firstIndex(where: { $0.id == file.id }) {
                    files[currentIndex].status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func generateWaveform(_ file: FileItem) {
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: file.url)
                if let currentIndex = files.firstIndex(where: { $0.id == file.id }) {
                    files[currentIndex].waveform = waveform
                }
            } catch {
                // Waveform generation failed silently - not critical
            }
        }
    }

    private func generateOutputWaveform(id: UUID, url: URL) {
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: url)
                if let currentIndex = files.firstIndex(where: { $0.id == id }) {
                    files[currentIndex].outputWaveform = waveform
                }
            } catch {
                // Output waveform generation failed — non-critical, processed file is unaffected
            }
        }
    }
}
