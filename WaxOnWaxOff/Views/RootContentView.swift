import AppKit
import SwiftUI

struct RootContentView: View {
    @Environment(AppState.self) var appState
    @State private var waxOnVM  = ContentViewModel()
    @State private var waxOffVM = DeliveryViewModel()

    var body: some View {
        Group {
            if appState.mode == .waxOn {
                ContentView(viewModel: waxOnVM)
            } else {
                WaxOffMainView(viewModel: waxOffVM)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            waxOnVM.cancelProcessing()
            waxOffVM.cancelProcessing()
        }
    }
}
