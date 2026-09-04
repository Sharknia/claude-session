import SwiftUI

@main
struct ClaudeSessionWarmerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Claude Session Warmer", systemImage: "clock.arrow.circlepath") {
            MenuContent(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
