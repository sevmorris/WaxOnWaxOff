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
            }
        }

        Window("WaxOn/WaxOff Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}
