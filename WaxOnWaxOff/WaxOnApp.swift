//
//  WaxOnApp.swift
//  WaxOn
//
//  Created by Seven Morris on 11/15/25.
//

import AppKit
import SwiftUI

@main
struct WaxOnWaxOffApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

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
