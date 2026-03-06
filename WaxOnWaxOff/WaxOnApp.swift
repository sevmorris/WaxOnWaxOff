//
//  WaxOnApp.swift
//  WaxOn
//
//  Created by Seven Morris on 11/15/25.
//

import SwiftUI

@main
struct WaxOnWaxOffApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        Task {
            let result = await UpdateChecker().check()
            if case .available = result {
                await checkForUpdates()
            }
        }
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

                Divider()

                Button("Send Feedback…") {
                    if let url = URL(string: "mailto:7morris@gmail.com?subject=WaxOnWaxOff%20Feedback") {
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
