import AppKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "DeliveryVM")

@Observable
@MainActor
final class DeliveryViewModel {
    let fileQueue = FileQueueCoordinator()
    var settings: WaxOffSettings {
        didSet { settings.save() }
    }
    var isProcessing = false
    /// Live processing phase per file, keyed by `FileItem.id`. Delivery runs
    /// concurrently, so a single shared phase string would show whichever file
    /// emitted last, attributed to none of them (#23). An entry goes in on
    /// `onPhase` and comes out when that file reaches a terminal state —
    /// completed or failed — not when the batch ends.
    var filePhases: [UUID: String] = [:]
    /// Completed verification passes for the current batch, or nil when none is
    /// running. Batch-level, not per-file: a row reaches `.processed` when its
    /// output is written, before its own verification runs, so verification
    /// cannot be attributed to a row. No denominator — see `drainVerifications`.
    var verificationsCompleted: Int? = nil
    /// True only during the verification tail: every file is written and the
    /// verification pool is still draining. Distinct from
    /// `verificationsCompleted`, which goes non-nil as soon as the first
    /// verification finishes — and verifications drain concurrently with
    /// delivery, so on a multi-file batch that happens while files are still
    /// being written. Driven by `onDeliveryComplete`, which fires once at the
    /// delivering-to-verifying boundary.
    var isVerifying = false
    var alertMessage: String?
    var showWaxoffWarning = false
    private var pendingWaxoffFiles: [URL] = []
    var presetStore = WaxOffPresetStore()
    var log = ProcessingLog()

    private var processingTask: Task<Void, Never>?
    private var processingCancelled = false

    var files: [FileItem] {
        get { fileQueue.files }
        set { fileQueue.files = newValue }
    }
    var selectedFileIDs: Set<UUID> {
        get { fileQueue.selectedFileIDs }
        set { fileQueue.selectedFileIDs = newValue }
    }
    var isAnyFileAnalyzing: Bool { fileQueue.isAnyFileAnalyzing }

    /// True from the moment a restart is scheduled until the new batch starts.
    ///
    /// `cancelProcessing()` clears `isProcessing` synchronously, but the restart
    /// cannot begin until the outstanding task finishes unwinding — which means
    /// SIGTERM to every live ffmpeg/ffprobe and the task group waiting on each
    /// one. Without this flag that gap reads as idle: the toolbar falls through
    /// to an enabled Process button, and a second press takes the start path,
    /// producing a batch that the *outstanding* task's cleanup then clobbers.
    private(set) var isRestarting = false

    /// Whether `process()` will start a batch rather than return.
    ///
    /// Idle starts, obviously. The verification tail also starts: delivery is
    /// finished, every file is written, and the only outstanding work is the
    /// advisory re-measurement, which cancelling costs nothing on disk.
    /// Active delivery does not — a restart there would abandon renders in
    /// progress, and that is a different bargain entirely.
    ///
    /// `!isRestarting` is part of the answer, not a detail. During a restart
    /// `isProcessing` is already false, so the rest of this expression says
    /// true while `process()` in fact returns at its guard — the property
    /// promised something it had stopped delivering the moment that guard was
    /// added. Behaviour never depended on the difference (the re-entry branch
    /// below is only reached when `isRestarting` is already false), but the
    /// toolbar reads this to decide whether to offer Process, and it has to be
    /// asking a question the model actually answers.
    var canStartNewBatch: Bool { !isRestarting && (!isProcessing || isVerifying) }

    /// Which set of action controls the toolbar shows.
    ///
    /// One place decides. The toolbar previously walked the same three flags in
    /// its own if/else chain, so the rule "Process is offered exactly when
    /// `canStartNewBatch` is true" held only by the two happening to agree —
    /// nothing named it and nothing tested it. `toolbarStateOffersProcess`
    /// pins it now.
    ///
    /// Order is the meaning: a restart is in flight even though `isProcessing`
    /// is already false, and the tail is a kind of processing, so both have to
    /// be asked about before the plain `isProcessing` case.
    enum ToolbarState {
        /// Idle. Process starts a batch.
        case idle
        /// Renders in progress. Cancel only — a restart here abandons them.
        case delivering
        /// Files written, verification draining. Stop verifying, and Process.
        case verifying
        /// Previous batch cancelled and unwinding, next one not yet started.
        case restarting
    }

    var toolbarState: ToolbarState {
        if isRestarting { return .restarting }
        if isProcessing && isVerifying { return .verifying }
        if isProcessing { return .delivering }
        return .idle
    }

    /// Whether the file list can be edited.
    ///
    /// Delivery is writing renders for the rows it holds and the restart is
    /// about to, so removing them there orphans the batch's UI state without
    /// stopping any of the work — the callbacks simply stop finding their rows.
    /// The verification tail is editable on purpose: those files are already on
    /// disk, and refusing edits there would contradict the whole point of
    /// letting a new batch start during the window.
    var canEditFileList: Bool {
        switch toolbarState {
        case .idle, .verifying: return true
        case .delivering, .restarting: return false
        }
    }

    /// True when every loaded file with known channel info is single-channel. The mono
    /// delivery control only applies to mono sources; for stereo, mixed, or an empty
    /// queue it stays inert. (The pipeline independently ignores the setting for any
    /// stereo source, so this only governs whether the control is enabled in the UI.)
    var allLoadedSourcesMono: Bool {
        let known = files.compactMap(\.fileInfo)
        guard !known.isEmpty else { return false }
        return known.allSatisfy { $0.channelCount == 1 }
    }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. RootContentView's @State view model being discarded when the
    // window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    init() {
        self.settings = WaxOffSettings.load()
        if let preset = presetStore.selectedPreset {
            settings = preset.settings
        }
    }

    func addFiles(_ urls: [URL]) {
        alertMessage = fileQueue.addFiles(
            urls,
            skippedFormatMessage: { count in
                "\(count) file\(count == 1 ? "" : "s") skipped — unsupported format."
            },
            beforeCommit: { valid in
                if valid.contains(where: OutputNaming.looksLikeWaxOffDelivery) {
                    self.pendingWaxoffFiles = valid
                    self.showWaxoffWarning = true
                    return false
                }
                return true
            }
        )
    }

    func confirmWaxoffWarning() {
        let toAdd = pendingWaxoffFiles
        pendingWaxoffFiles = []
        showWaxoffWarning = false
        fileQueue.commitFiles(toAdd)
    }

    func dismissWaxoffWarning() {
        pendingWaxoffFiles = []
        showWaxoffWarning = false
    }

    // Guarded here rather than at each call site. Disabling the toolbar's
    // Remove and Clear covered one route into these and left the list's own
    // two — swipe-to-delete and the Delete key — wide open, so the rule held
    // only where somebody had remembered to apply it. Same shape as the
    // toolbar deriving its own state: a rule enforced by the view is a rule
    // with holes in it.
    func removeSelected() {
        guard canEditFileList else { return }
        fileQueue.removeSelected()
    }
    func clearAll() {
        guard canEditFileList else { return }
        fileQueue.clearAll()
    }
    func removeFiles(at offsets: IndexSet) {
        guard canEditFileList else { return }
        fileQueue.removeFiles(at: offsets)
    }
    // Not guarded: reordering removes nothing, and the batch matches its
    // callbacks to rows by id rather than by position.
    func moveFiles(from source: IndexSet, to destination: Int) { fileQueue.moveFiles(from: source, to: destination) }

    func applyPreset(_ preset: WaxOffPreset) {
        settings = preset.settings
        presetStore.selectPreset(preset.id)
    }

    func saveCurrentAsPreset(name: String) {
        presetStore.savePreset(WaxOffPreset(name: name, settings: settings))
    }

    func process() {
        // `isRestarting` closes the window the re-entry branch below opens.
        // Awaiting the outstanding task was never enough on its own: it orders
        // the *restart* correctly, but the user is a second caller. Between
        // `cancelProcessing()` and the restart firing, `isProcessing` is already
        // false, so a second press fell straight through to the start path — and
        // the outstanding task's cleanup then landed on that new batch, leaving
        // it rendering with `isProcessing` false and `processingTask` nil: no
        // Cancel, no readout, and a third press able to start yet another batch
        // over the same output paths.
        guard !files.isEmpty, !isRestarting else { return }

        // Re-entry. Until now nothing here blocked a second call — the toolbar
        // hiding Process was the only thing preventing it, which left a UI
        // detail standing in for a state invariant.
        //
        // During the tail the outstanding task is cancelled first, then awaited
        // before restarting. Awaiting matters: a cancelled task still unwinds
        // through the cleanup at the end of this method's Task, which clears
        // isProcessing / isVerifying / verificationsCompleted. Start the new
        // batch without waiting and that cleanup lands on the new batch's
        // state, leaving it running with the UI believing nothing is.
        //
        // Already-delivered rows are .processed, and the ready-file filter
        // below only takes .ready — so a restart cannot reprocess the previous
        // batch. That is by construction, not by clearing the list.
        if isProcessing {
            guard canStartNewBatch, let outstanding = processingTask else { return }
            isRestarting = true
            cancelProcessing()
            Task { @MainActor [weak self] in
                _ = await outstanding.value
                // Cleared immediately before re-entering, so the guard above
                // holds for the whole unwind and not a moment longer.
                self?.isRestarting = false
                self?.process()
            }
            return
        }

        if let customPath = settings.outputDirectoryPath,
           !FileManager.default.isWritableFile(atPath: customPath) {
            alertMessage = "Output directory is not writable: \(customPath)"
            return
        }

        // Fail closed on files whose fileInfo is nil — analysis either failed or
        // hasn't finished yet, so channel count is unknown. Mono files are handled
        // correctly by DeliveryProcessor (upmixed to dual-mono before loudnorm).
        var analysisIncompleteCount = 0
        for i in files.indices {
            guard case .ready = files[i].status else { continue }
            guard files[i].fileInfo != nil else {
                files[i].status = .error("File analysis incomplete — channel count could not be determined. Wait for analysis to finish, then try again.")
                analysisIncompleteCount += 1
                continue
            }
        }

        let readyFiles = files.filter {
            if case .ready = $0.status { return true }
            return false
        }
        guard !readyFiles.isEmpty else {
            if analysisIncompleteCount > 0 {
                alertMessage = "No processable files — wait for file analysis to complete, then try again."
            } else {
                alertMessage = "No files are ready to process — wait for analysis to finish or fix errors first."
            }
            return
        }

        let outputDirectories = readyFiles.map { file in
            OutputDirectory.waxOffOutputDirectory(for: file.url, settings: settings)
        }
        if let reason = OutputDirectory.unwritableReason(outputDirectories) {
            alertMessage = reason
            return
        }

        guard OutputDirectory.confirmDesktopFallback(outputDirectories: outputDirectories) else { return }

        if let reason = DiskSpaceChecker.waxOffBatchBlockedReason(
            inputURLs: readyFiles.map(\.url),
            outputDirectories: outputDirectories
        ) {
            alertMessage = reason
            return
        }

        isProcessing = true
        isVerifying = false
        processingCancelled = false
        log.clear()
        fileQueue.snapshotReadyStats()

        let currentSettings = settings
        let inputs = readyFiles.map { DeliveryJobInput(id: $0.id, url: $0.url) }

        processingTask = Task {
            do {
                let processor = DeliveryProcessor()
                let batch = try await processor.run(
                    inputs: inputs,
                    settings: currentSettings,
                    onFileStarted: { [weak self] id in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            guard !self.processingCancelled else { return }
                            guard let idx = self.files.firstIndex(where: { $0.id == id }) else { return }
                            self.files[idx].status = .processing
                        }
                    },
                    onFileCompleted: { [weak self] result in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            // Terminal state for this file: its phase entry goes
                            // out here, not at batch end. Removed before the
                            // status guard so a file with no output URL cannot
                            // leave a stale entry behind.
                            self.filePhases.removeValue(forKey: result.id)
                            guard let idx = self.files.firstIndex(where: { $0.id == result.id }),
                                  let primaryURL = result.outputURLs.first else { return }
                            self.files[idx].status = .processed(outputURL: primaryURL)
                            // Refresh the stats panel and output waveform against
                            // the rendered file (single shared decode) so the user
                            // can see what their WaxOff output landed at — mirrors
                            // WaxOn's post-process behavior.
                            self.fileQueue.analyzeOutputFile(id: result.id, url: primaryURL)
                        }
                    },
                    onFileFailed: { [weak self] failure in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            // The other terminal state — same removal, or a
                            // failed file keeps a phase on its row forever.
                            self.filePhases.removeValue(forKey: failure.id)
                            guard let idx = self.files.firstIndex(where: { $0.id == failure.id }) else { return }
                            // The reason, not a pointer to it. WaxOn has always
                            // put `failure.message` on the row; WaxOff was
                            // handed the same message and discarded it for a
                            // constant, which sent the user to the console to
                            // read something the row could have said.
                            self.files[idx].status = .error(failure.message)
                        }
                    },
                    onPhase: { [weak self] id, phase in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.files.contains(where: { $0.id == id && $0.status == .processing }) else { return }
                            self.filePhases[id] = phase
                        }
                    },
                    onDeliveryComplete: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.isVerifying = true
                        }
                    },
                    onVerificationProgress: { [weak self] completed in
                        Task { @MainActor [weak self] in
                            self?.verificationsCompleted = completed
                        }
                    },
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    }
                )

                fileQueue.restoreProcessingRows()

                let partials = batch.successes.filter { $0.mp3FailureMessage != nil }
                if !batch.successes.isEmpty {
                    if !partials.isEmpty {
                        alertMessage = "\(partials.count) file\(partials.count == 1 ? "" : "s") had MP3 encoding failure (WAV complete). See Console for details."
                    }
                    NotificationService.showCompletionNotification(
                        mode: .waxOff,
                        fileCount: batch.successes.count
                    )
                } else if !batch.failures.isEmpty {
                    alertMessage = "Processing failed. Select the console button at the top right of the waveform area to see the details."
                }
            } catch is CancellationError {
                // User cancelled — cancelProcessing() already restored row state
            } catch {
                logger.error("Processing failed: \(error.localizedDescription, privacy: .public)")
                log.append("✗ \(error.localizedDescription)", level: .info)
                fileQueue.restoreProcessingRows()
                alertMessage = "Processing failed. Select the console button at the top right of the waveform area to see the details."
            }

            isProcessing = false
            isVerifying = false
            verificationsCompleted = nil
            // Safety net only. Phases are cleared per file on completion or
            // failure above; this catches an entry orphaned by a path that
            // reached neither — it is no longer what makes the readout correct.
            filePhases.removeAll()
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingCancelled = true
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        isVerifying = false
        verificationsCompleted = nil
        filePhases.removeAll()
        fileQueue.restoreProcessingRowsAfterCancel()
    }
}
