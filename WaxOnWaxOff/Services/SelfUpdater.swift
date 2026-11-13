// Shared verbatim across the sibling app repos (DoublEnder, WaxOnWaxOff,
// ClipHack, FilmStrip, KeyVault, Magic Backup Machine, Barkeep, PasswordGen,
// Dipstick). Keep the copies byte-identical: scripts/check-shared.sh compares
// them and a release preflight fails when they drift. Anything app-specific
// belongs in that app's UpdateChecker, which fills in a SelfUpdatePrompt.

import AppKit
import Security

/// Installs a new version over the running app, so an update takes one click
/// rather than a DMG to open and a drag to Applications.
///
/// What makes a download trustworthy is its signature, not where it came from.
/// Every release's DMG and the app inside it are signed with the Developer ID
/// below, and nothing is mounted or installed until the signature checks out.
/// No key or feed exists beyond what a release already publishes.
///
/// The swap happens in this process, while the app is still running. macOS
/// lets an app change one signed by its own team without the App Management
/// permission, and it holds whoever makes the change responsible, which a
/// helper left running after the app quits would blur.
nonisolated enum SelfUpdater {

    /// Why this copy cannot replace itself. Each falls back to the Download
    /// button, which needs none of this.
    nonisolated enum Obstacle: Equatable {
        /// A development build: it would be replacing itself, wherever Xcode
        /// put it, with something that is not what it was built from.
        case notARelease
        /// On a mounted DMG, or translocated by Gatekeeper because it was
        /// opened where it was downloaded without being moved.
        case readOnlyLocation
        /// Installed by another user on this Mac, for one.
        case notWritable
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case http(Int)
        case untrusted
        case notNewer
        case needsNewerMacOS(String)
        case wrongArchitecture
        case diskImage
        case copy
        case swap(String)
        case noSpace
        case timedOut

        var errorDescription: String? {
            switch self {
            case .http(let status):
                return "The download failed (HTTP \(status))."
            case .untrusted:
                return "The download isn't a signed release of this app, so nothing was installed."
            case .notNewer:
                // Where the download comes from a fixed link rather than the
                // release itself, a release is public moments before its DMG
                // reaches the link, and the link may be cached.
                return "The new version is still being published. Try again in a few minutes."
            case .needsNewerMacOS(let minimum):
                return "The new version needs macOS \(minimum)."
            case .wrongArchitecture:
                return "The new version doesn't run on this Mac's processor."
            case .diskImage:
                return "The downloaded disk image couldn't be opened."
            case .copy:
                return "The new version couldn't be copied out of its disk image."
            case .swap(let reason):
                return "The app couldn't be replaced: \(reason)."
            case .noSpace:
                return "There isn't enough free disk space to install the new version."
            case .timedOut:
                return "Installing the new version took too long."
            }
        }
    }

    // MARK: - Trust

    /// Every release's designated requirement, less its identifier: a Developer
    /// ID Application certificate from Apple, issued to this team. A DMG meets
    /// this one alone, because its identifier is taken from its file name.
    static let developerIDRequirement = """
        anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "T9RLNAXPWU"
        """

    static func appRequirement(bundleID: String) -> String {
        "identifier \"\(bundleID)\" and \(developerIDRequirement)"
    }

    /// True when the app or disk image at `url` is intact, in every
    /// architecture and nested item, and signed as `requirement` says.
    static func isSigned(_ url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, parsed) == errSecSuccess
    }

    // MARK: - Whether this copy can update

    static func obstacle(for app: URL, requirement: String) -> Obstacle? {
        guard isSigned(app, requirement: requirement) else { return .notARelease }
        let volume = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeSupportsSwapRenamingKey])
        if let obstacle = locationObstacle(readOnly: volume?.volumeIsReadOnly ?? false,
                                           translocated: isTranslocated(app),
                                           supportsSwap: volume?.volumeSupportsSwapRenaming) {
            return obstacle
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.path),
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return .notWritable }
        return nil
    }

    static func isTranslocated(_ app: URL) -> Bool {
        app.path.contains("/AppTranslocation/")
    }

    /// Where the copy is, as an obstacle. A volume that cannot exchange two
    /// items in one step (exFAT, a network share) counts with the read-only
    /// ones: the update would download and stage, then fail at the swap, every
    /// time. A volume that does not say is taken to be able to.
    static func locationObstacle(readOnly: Bool, translocated: Bool, supportsSwap: Bool?) -> Obstacle? {
        readOnly || translocated || supportsSwap == false ? .readOnlyLocation : nil
    }

    // MARK: - Vetting a new version

    /// What a download has to be to replace this copy.
    nonisolated struct Expected {
        var bundleID: String
        var installedVersion: String
        var appRequirement: String
        var diskImageRequirement = SelfUpdater.developerIDRequirement
        var os = ProcessInfo.processInfo.operatingSystemVersion
        var architecture = SelfUpdater.runningArchitecture

        static func running(_ bundle: Bundle) -> Expected {
            let bundleID = bundle.bundleIdentifier ?? ""
            return Expected(bundleID: bundleID,
                            installedVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                            appRequirement: SelfUpdater.appRequirement(bundleID: bundleID))
        }
    }

    static var runningArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    /// `"1.6.28lr"` → `"1.6.28"`: the part of a version that compares, without
    /// a flavour suffix such as DoublEnder's `lr` and `cr`.
    static func numericVersion(_ version: String) -> String {
        String(version.prefix { $0.isNumber || $0 == "." })
    }

    /// Everything that would leave a Mac with a worse app than it has: the
    /// update replaces the only copy, so an app that will not open here has to
    /// be stopped now. The arm64-only builds of DoublEnder that once shipped as
    /// universal would have broken every Intel Mac this way.
    static func vet(_ app: URL, against expected: Expected) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == expected.bundleID,
              isSigned(app, requirement: expected.appRequirement) else { throw Failure.untrusted }

        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard numericVersion(version)
            .compare(numericVersion(expected.installedVersion), options: .numeric) == .orderedDescending
        else { throw Failure.notNewer }

        if let minimum = (bundle.infoDictionary?["LSMinimumSystemVersion"] as? String).flatMap(macOSVersion),
           (expected.os.majorVersion, expected.os.minorVersion, expected.os.patchVersion)
            < (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion) {
            throw Failure.needsNewerMacOS("\(minimum.majorVersion).\(minimum.minorVersion)")
        }
        guard bundle.executableArchitectures?.contains(where: { $0.intValue == expected.architecture }) == true
        else { throw Failure.wrongArchitecture }
    }

    /// "15", "15.0" or "15.2.1" as a version; nil for anything else.
    private static func macOSVersion(_ string: String) -> OperatingSystemVersion? {
        let numbers = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), !numbers.contains(nil) else { return nil }
        return OperatingSystemVersion(majorVersion: numbers[0]!,
                                      minorVersion: numbers.count > 1 ? numbers[1]! : 0,
                                      patchVersion: numbers.count > 2 ? numbers[2]! : 0)
    }

    /// The one app at the top of a mounted release DMG, whatever it is named.
    /// Beside it are only the /Applications link and the installer window's art.
    static func app(in volume: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw Failure.untrusted }
        return apps[0]
    }

    // MARK: - Staging

    /// How staging runs hdiutil and ditto. A test passes its own, to make a
    /// tool fail, hang or be cancelled without a disk image that does so.
    nonisolated struct Tools: Sendable {
        nonisolated enum Outcome: Sendable, Equatable {
            /// It exited with status 0.
            case success
            case failure
            /// It was still running at its deadline, and was stopped.
            case timedOut
            /// `isCancelled` turned true while it ran, and it was stopped.
            case cancelled
        }

        var run: @Sendable (_ tool: String, _ arguments: [String], _ deadline: TimeInterval,
                            _ isCancelled: @Sendable () -> Bool) -> Outcome

        static let system = Tools(run: { tool, arguments, deadline, isCancelled in
            SelfUpdater.runTool(tool, arguments, deadline: deadline, isCancelled: isCancelled)
        })
    }

    /// What a download may take. The defaults bound what had no bound: an idle
    /// connection was given up after a minute, and a trickle never.
    nonisolated struct DownloadLimits: Sendable {
        /// Seconds without a byte before the download is given up.
        var stallTimeout: TimeInterval = 30
        /// Seconds for the whole download.
        var resourceTimeout: TimeInterval = 15 * 60
        /// A release is tens of megabytes. Anything past this is not one.
        var maximumBytes: Int64 = 1 << 30
        /// Free space that has to be left over, on top of what the update
        /// needs: room for whatever else the app is writing meanwhile.
        var reserve: Int64 = 0

        init(stallTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 15 * 60,
             maximumBytes: Int64 = 1 << 30, reserve: Int64 = 0) {
            self.stallTimeout = stallTimeout
            self.resourceTimeout = resourceTimeout
            self.maximumBytes = maximumBytes
            self.reserve = reserve
        }
    }

    /// The scratch folders `stage(from:)` makes in the temporary directory start
    /// with this, so an app can find the ones a quit or a crash left behind.
    static let scratchPrefix = "SelfUpdate-"

    /// Generous, since the largest sibling's image is some hundred megabytes on
    /// what may be a slow disk; a tool past these is not slow but stuck.
    private static let attachDeadline: TimeInterval = 120
    private static let copyDeadline: TimeInterval = 300
    private static let detachDeadline: TimeInterval = 30

    /// The mount, copy and validation block their thread for seconds. They get a
    /// queue of their own, at a priority that gives way to the app's own work,
    /// rather than a thread of the concurrency pool.
    private static let stagingQueue = DispatchQueue(label: "SelfUpdater.staging", qos: .utility)

    nonisolated private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
    }

    /// Downloads a release and leaves a vetted copy of its app on the same
    /// volume as `installed`, where the swap can be a rename. The caller
    /// disposes of it with `discard`.
    ///
    /// Cancelling the task stops it wherever it is: the download, or the tool
    /// that is running. `holder`, when given, is an existing folder on the
    /// installed app's volume to stage into, so the caller knows where the copy
    /// is before it exists; nil makes one.
    static func stage(from request: URLRequest, replacing installed: URL, expected: Expected,
                      limits: DownloadLimits = DownloadLimits(), tools: Tools = .system,
                      into holder: URL? = nil, configuration: URLSessionConfiguration? = nil,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(scratchPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dmg = scratch.appendingPathComponent("update.dmg")
        try await UpdateDownload.fetch(request, to: dmg, limits: limits, configuration: configuration,
                                       progress: progress)
        try Task.checkCancellation()

        let cancelled = CancelFlag()
        let staged = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                stagingQueue.async {
                    continuation.resume(with: Result {
                        try stage(diskImage: dmg, replacing: installed, expected: expected, tools: tools,
                                  into: holder, reserve: limits.reserve, isCancelled: { cancelled.isSet })
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
        do {
            try Task.checkCancellation()
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    /// The disk image half of `stage`. It blocks while the image mounts and copies.
    static func stage(diskImage dmg: URL, replacing installed: URL, expected: Expected,
                      tools: Tools = .system, into holder: URL? = nil, reserve: Int64 = 0,
                      isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        // Before hdiutil has to parse it: an unsigned image is never mounted.
        guard isSigned(dmg, requirement: expected.diskImageRequirement) else { throw Failure.untrusted }
        if isCancelled() { throw CancellationError() }

        let mountPoint = dmg.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try check(tools.run("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mountPoint.path,
                                                 "-nobrowse", "-noautoopen", "-readonly", "-quiet"],
                            attachDeadline, isCancelled),
                  or: .diskImage)
        // Whatever stopped the rest, the image comes off again.
        defer {
            _ = tools.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"],
                          detachDeadline, { false })
        }

        let app = try app(in: mountPoint)
        try vet(app, against: expected)
        if isCancelled() { throw CancellationError() }

        let folder = try holder ?? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                           appropriateFor: installed, create: true)
        let staged = folder.appendingPathComponent(installed.lastPathComponent)
        do {
            // Before the copy fills what is left of the disk.
            if let free = freeSpace(at: folder), free < allocatedSize(of: app) + reserve {
                throw Failure.noSpace
            }
            try check(tools.run("/usr/bin/ditto", [app.path, staged.path], copyDeadline, isCancelled),
                      or: .copy)
            // The copy is what gets installed, so it is the one that has to pass.
            guard isSigned(staged, requirement: expected.appRequirement) else { throw Failure.copy }
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    private static func check(_ outcome: Tools.Outcome, or failure: Failure) throws {
        switch outcome {
        case .success: return
        case .failure: throw failure
        case .timedOut: throw Failure.timedOut
        case .cancelled: throw CancellationError()
        }
    }

    /// Removes a staged copy and the folder made for it. After a swap, that
    /// copy is the previous version.
    static func discard(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Free space on the volume holding `url`, as the system counts it for
    /// work the user asked for; nil when the volume does not say.
    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// What `item` and everything in it takes up on disk.
    static func allocatedSize(of item: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: item, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Runs a tool to its end, its deadline or its cancellation, whichever is
    /// first. A tool that is stopped is asked to quit and, two seconds on, made
    /// to: a hung hdiutil used to hold the update, and its window, for ever.
    static func runTool(_ tool: String, _ arguments: [String], deadline: TimeInterval,
                        isCancelled: @Sendable () -> Bool) -> Tools.Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Never urgent, and the app may be busy with work that is.
        process.qualityOfService = .utility
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure
        }
        let end = Date().addingTimeInterval(deadline)
        while exited.wait(timeout: .now() + 0.1) == .timedOut {
            let cancelled = isCancelled()
            guard cancelled || Date() >= end else { continue }
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            return cancelled ? .cancelled : .timedOut
        }
        return process.terminationStatus == 0 ? .success : .failure
    }

    // MARK: - Installing

    /// Exchanges the staged app and the installed one in a single step, so a
    /// failure at any point leaves the installed app whole. The running process
    /// keeps its own files open and carries on until it quits.
    static func swap(staged: URL, into installed: URL) throws {
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure.swap(String(cString: strerror(errno)))
        }
    }

    /// Opens `app` once this process has gone, so two copies never run at once.
    /// It gives up after a minute rather than linger if the quit is somehow refused.
    static func relaunch(_ app: URL) throws {
        let script = """
            i=0
            while kill -0 "$1" 2>/dev/null; do
                i=$((i + 1))
                [ "$i" -gt 300 ] && exit 1
                sleep 0.2
            done
            exec /usr/bin/open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try process.run()
    }
}

// MARK: - The prompt

/// What an app tells the update flow. Everything else is the same in every app.
@MainActor
struct SelfUpdatePrompt {
    var appName: String
    var version: String
    /// The DMG. Also what the Download button opens when this copy can't update itself.
    var downloadURL: URL
    /// How to fetch the DMG, when `downloadURL` alone won't do: a private
    /// repository's asset needs a token. nil requests `downloadURL`.
    var installRequest: URLRequest?
    /// nil leaves out the Release Notes button.
    var releaseURL: URL?
    /// nil keeps the system's alert appearance.
    var appearance: NSAppearance?
    /// True while the app is doing something a relaunch would cut short.
    var isBusy: @MainActor () -> Bool = { false }
    /// Shown while the update waits for `isBusy` to clear.
    var busyMessage = ""
}

/// The prompt, the progress window and the relaunch.
@MainActor
enum SelfUpdateFlow {
    private static var activeWindow: UpdateProgressWindow?

    /// True when an update is already under way, whose window is brought forward.
    static func bringForward() -> Bool {
        guard let activeWindow else { return false }
        activeWindow.bringForward()
        return true
    }

    /// Offers the update. `silent` is the check at launch, which can answer after
    /// work has begun, and nothing should appear on top of that. The next launch
    /// offers it again. Returns true when the user chose Not Now.
    @discardableResult
    static func offer(_ prompt: SelfUpdatePrompt, silent: Bool) async -> Bool {
        if silent && prompt.isBusy() { return false }

        let app = Bundle.main.bundleURL
        let requirement = SelfUpdater.Expected.running(.main).appRequirement
        let obstacle = await Task.detached { SelfUpdater.obstacle(for: app, requirement: requirement) }.value
        // Asked again: work may have begun while the copy was being checked,
        // and from here to the prompt nothing suspends.
        if silent && prompt.isBusy() { return false }

        let alert = makeAlert(prompt)
        alert.messageText = "Update Available"
        alert.informativeText = "\(prompt.appName) \(prompt.version) is available."
        if let obstacle {
            alert.informativeText += " " + explanation(of: obstacle, at: app)
        }
        alert.addButton(withTitle: obstacle == nil ? "Update and Relaunch" : "Download")
        if prompt.releaseURL != nil {
            alert.addButton(withTitle: "Release Notes")
        }
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if obstacle == nil {
                await install(prompt)
            } else {
                NSWorkspace.shared.open(prompt.downloadURL)
            }
        } else if response == .alertSecondButtonReturn, let releaseURL = prompt.releaseURL {
            NSWorkspace.shared.open(releaseURL)
        } else {
            return true
        }
        return false
    }

    /// Downloads and vets the update, replaces this copy and relaunches. Any
    /// failure leaves the installed app as it was and offers the download instead.
    private static func install(_ prompt: SelfUpdatePrompt) async {
        let window = UpdateProgressWindow(title: "Updating \(prompt.appName)", appearance: prompt.appearance)
        activeWindow = window
        let downloading = "Downloading \(prompt.appName) \(prompt.version)…"
        window.showProgress(downloading, fraction: 0)
        window.show()

        let work = Task { @MainActor in
            let installed = Bundle.main.bundleURL
            let request = prompt.installRequest
                ?? URLRequest(url: prompt.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
            let staged = try await SelfUpdater.stage(from: request, replacing: installed,
                                                     expected: .running(.main)) { fraction in
                Task { @MainActor in
                    window.showProgress(fraction < 1 ? downloading : "Checking the download…",
                                        fraction: fraction < 1 ? fraction : nil)
                }
            }
            do {
                // Work started during the download, or under way when this began,
                // is left to finish. Once it has, its results are on screen and a
                // relaunch would clear them, so that is the user's call.
                var waited = false
                repeat {
                    while prompt.isBusy() {
                        waited = true
                        window.showProgress(prompt.busyMessage, fraction: nil)
                        try await Task.sleep(for: .seconds(1))
                    }
                    if waited, !confirmRelaunch(prompt) { throw CancellationError() }
                } while prompt.isBusy()
                // No suspension from here to the quit, so no work can start in between.
                try SelfUpdater.swap(staged: staged, into: installed)
            } catch {
                SelfUpdater.discard(staged)
                throw error
            }
            SelfUpdater.discard(staged)
            try? SelfUpdater.relaunch(installed)
            NSApp.terminate(nil)
        }
        window.setCancelAction { work.cancel() }

        let outcome = await work.result
        window.close()
        activeWindow = nil

        guard !work.isCancelled, case .failure(let error) = outcome, !(error is CancellationError) else { return }
        let alert = makeAlert(prompt)
        alert.messageText = "Couldn't Install the Update"
        alert.informativeText = "\(error.localizedDescription) \(prompt.appName) has not changed. You can download the new version and install it yourself."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(prompt.downloadURL)
        }
    }

    private static func confirmRelaunch(_ prompt: SelfUpdatePrompt) -> Bool {
        let alert = makeAlert(prompt)
        alert.messageText = "\(prompt.appName) \(prompt.version) Is Ready to Install"
        alert.informativeText = "Relaunch now to finish updating, or choose Not Now to update later."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func makeAlert(_ prompt: SelfUpdatePrompt) -> NSAlert {
        let alert = NSAlert()
        if let appearance = prompt.appearance {
            alert.window.appearance = appearance
        }
        return alert
    }

    /// Why this copy has to be replaced by hand.
    private static func explanation(of obstacle: SelfUpdater.Obstacle, at app: URL) -> String {
        switch obstacle {
        case .notARelease:
            return "This copy isn't a signed release, so it can't replace itself."
        case .readOnlyLocation:
            return "This copy can't replace itself where it is. Move it to the Applications folder and open it from there."
        case .notWritable:
            return "You don't have permission to replace the copy at \(app.path)."
        }
    }
}

// MARK: - Download

/// A download with progress. The async `download(for:delegate:)` does not report
/// any, so this keeps to the delegate calls, which run on the session's serial queue.
nonisolated private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limits: SelfUpdater.DownloadLimits
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var sizeChecked = false

    private init(destination: URL, limits: SelfUpdater.DownloadLimits, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.limits = limits
        self.progress = progress
    }

    static func fetch(_ request: URLRequest, to destination: URL, limits: SelfUpdater.DownloadLimits,
                      configuration: URLSessionConfiguration?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = UpdateDownload(destination: destination, limits: limits, progress: progress)
        let configuration = configuration ?? .ephemeral
        configuration.timeoutIntervalForRequest = limits.stallTimeout
        configuration.timeoutIntervalForResource = limits.resourceTimeout
        var request = request
        request.timeoutInterval = limits.stallTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        session.finishTasksAndInvalidate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Decided at the first bytes, when the size is known: something far too
        // large to be a release, or too large for the disk, is not fetched whole
        // to find that out.
        let size = max(totalBytesExpectedToWrite, totalBytesWritten)
        if !sizeChecked || totalBytesExpectedToWrite <= 0 {
            sizeChecked = true
            if size > limits.maximumBytes {
                failure = SelfUpdater.Failure.untrusted
            } else if let free = SelfUpdater.freeSpace(at: destination.deletingLastPathComponent()),
                      free < size + limits.reserve {
                failure = SelfUpdater.Failure.noSpace
            }
            if failure != nil {
                downloadTask.cancel()
                return
            }
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// The file is deleted when this returns, so it has to move now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard failure == nil else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            failure = SelfUpdater.Failure.http(status)
            return
        }
        // A body shorter than the server said it would be.
        let expected = downloadTask.countOfBytesExpectedToReceive
        if expected > 0, downloadTask.countOfBytesReceived != expected {
            failure = URLError(.networkConnectionLost)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    /// A failure this delegate found comes first: cancelling the task for it is
    /// what produced `error`.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let problem = failure ?? error {
            continuation?.resume(throwing: problem)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

// MARK: - Progress window

/// Shows how the update is going, with a way out.
///
/// This window is not modal, on purpose. The update runs on the main actor, and
/// `checkForUpdates` is a main actor task: a modal run loop started inside one
/// stops the main queue being serviced, so the download could never report back
/// or finish. It is why the app stays usable, too, and why installing waits for
/// its work rather than refusing to start.
@MainActor
private final class UpdateProgressWindow: NSObject {
    private let window: NSWindow
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private var onCancel: (() -> Void)?

    init(title: String, appearance: NSAppearance?) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancel])
        let stack = NSStackView(views: [label, bar, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 380),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
    }

    func setCancelAction(_ action: @escaping () -> Void) {
        onCancel = action
    }

    func show() {
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        // `center()` always picks the primary screen; the app may be on another.
        let screen = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        bringForward()
    }

    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }

    func showProgress(_ message: String, fraction: Double?) {
        label.stringValue = message
        if let fraction {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
