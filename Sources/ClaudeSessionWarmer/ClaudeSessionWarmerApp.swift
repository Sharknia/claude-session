import AppKit
import SwiftUI

@main
struct ClaudeSessionWarmerApp: App {
    @StateObject private var state = AppState()

    private var menuBarIcon: NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "Claude Session Warmer"
        ) ?? NSImage()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(nsImage: menuBarIcon)
                .accessibilityLabel("Claude Session Warmer")
        }
        .menuBarExtraStyle(.window)
    }
}
