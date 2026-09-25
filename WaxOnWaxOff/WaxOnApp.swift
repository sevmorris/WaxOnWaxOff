//
//  WaxOnApp.swift
//  WaxOn
//
//  Created by Seven Morris on 11/15/25.
//

import AppKit
import SwiftUI

/// Decides, before anything else runs, whether this launch is the app or only
/// the host for the unit tests.
///
/// Xcode runs the tests inside this app, so a test run used to launch all of
/// it: AppState read and re-saved the last mode in the app's real defaults,
/// the view models applied the selected preset and saved it over the
/// developer's settings, the launch checked for updates, and SwiftUI recorded
/// the window's frame. Hosting tests, the app now starts with no window, no
/// view model and no update check.
@main
enum AppLauncher {
    static func main() {
        if isHostingTests {
            TestHostApp.main()
        } else {
            WaxOnWaxOffApp.main()
        }
    }

    /// XCTest is already loaded when main() runs in a test host, and is never
    /// linked into the app itself. The session identifier is Xcode's own mark
    /// of a test launch, checked as well in case XCTest ever loads later.
    nonisolated static let isHostingTests =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
}

/// A scene with no window: while the app hosts the tests, nothing of the real
/// app is built.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

extension UserDefaults {
    /// Where the app keeps what it stores in defaults. It is the app's own
    /// domain — except in a test run, where `.standard` is that same domain,
    /// the developer's real settings, because the tests run inside the app.
    /// A test run gets a scratch suite in its place, so a test that forgets
    /// to pass a store of its own still cannot reach the real one. Nothing in
    /// the app names `.standard`; it goes through here.
    ///
    /// The scratch suite is named by a path in the temporary folder, which
    /// keeps its file out of ~/Library/Preferences, where the App Preferences
    /// source's io.github.sevmorris.* pattern would back it up.
    nonisolated static let app: UserDefaults = AppLauncher.isHostingTests
        ? UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appendingPathComponent("io.github.sevmorris.WaxOnWaxOff.tests").path)!
        : .standard
}

struct WaxOnWaxOffApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    /// Published by whichever mode is on screen. Nil before a mode is chosen,
    /// which is what disables the menu item on the mode picker.
    @FocusedValue(\.addFiles) private var addFiles

    init() {
        // Purge this instance's own PID-scoped temp directory in case it already
        // exists (same PID reused after a crash — rare, but safe to clear). Each
        // instance only touches its own subtree; concurrent instances are unaffected.
        let appTemp = FileManager.waxonTempDirectory
        try? FileManager.default.removeItem(at: appTemp)

        // On clean exit (Quit / Cmd+Q), remove the PID-scoped directory.
        // Force-quits and crashes leave it behind; macOS reclaims
        // NSTemporaryDirectory contents periodically.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            try? FileManager.default.removeItem(at: FileManager.waxonTempDirectory)
        }

        Task { await checkForUpdates(silent: true) }
    }

    var body: some Scene {
        WindowGroup {
            if appState.mode == nil {
                ModePicker()
                    .environment(appState)
                    .frame(width: 560, height: 320)
            } else {
                RootContentView()
                    .environment(appState)
            }
        }
        .commands {
            // `after:` rather than `replacing:` — the default New Window item
            // stays where it is; this only adds to that group.
            CommandGroup(after: .newItem) {
                Button("Add Files or Folder…") {
                    if let addFiles { AddFilesPanel.present(addFiles) }
                }
                .keyboardShortcut("o", modifiers: .command)
                // Until now drag-and-drop was the only way to get a file into
                // the app, and Cmd+O did nothing at all.
                .disabled(addFiles == nil)
            }

            CommandGroup(replacing: .help) {
                Button("WaxOn/WaxOff Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Check for Updates…") {
                    Task { await checkForUpdates() }
                }

                Button("Support WaxOn/WaxOff…") {
                    if let url = URL(string: "https://ko-fi.com/sevmo") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button("Send Feedback…") {
                    if let url = URL(string: "https://sevmorris.github.io/WaxOnWaxOff/#feedback") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/sevmorris/WaxOnWaxOff/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("WaxOn/WaxOff Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}
