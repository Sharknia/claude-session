import AppKit
import Combine
import SwiftUI

/// 같은 MenuContent를 메모리 설정과 가짜 서비스로 띄운다. 로그인도 외부 서비스에 접속하지 않는다.
@main
struct PreviewRecoveryMenu {
    @MainActor
    static func main() {
        guard let scenario = CommandLine.arguments.dropFirst().first,
              ["settings", "runtime", "future"].contains(scenario) else { exit(2) }
        let defaults = MemoryDefaults()
        let seed = SettingsStore(defaults: defaults)
        seed.saveDailyCycle(DailyCycle(dayKey: ScheduleEngine().dayKey(for: Date()), handledWindows: 1))
        seed.saveDailyCycle(DailyCycle(dayKey: ScheduleEngine().dayKey(for: Date()), handledWindows: 2))
        switch scenario {
        case "settings": defaults.set(Data("broken settings".utf8), forKey: SettingsStore.settingsKey)
        case "runtime": defaults.set(Data("broken runtime".utf8), forKey: "isolated.\(SettingsStore.runtimeFile)")
        default:
            defaults.set(Data(#"{"schemaVersion":9,"minimumReaderVersion":9,"value":{}}"#.utf8),
                         forKey: "isolated.\(SettingsStore.runtimeFile)")
        }
        let store = SettingsStore(defaults: defaults)
        let fake: @Sendable () -> Inspection = {
            Inspection(cliURL: URL(fileURLWithPath: "/unused-preview-cli"),
                       quota: QuotaWindow(active: false, usedPercent: 0), operationID: UUID().uuidString)
        }
        let state = AppState(store: store, startScheduler: false,
                             inspectClaude: { _ in fake() }, loginClaude: { fake() },
                             warmClaude: { _, _ in throw ClaudeServiceError.warmupNotStarted },
                             confirmationSleep: { _ in })
        let updater = AppUpdater(state: state)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "복구 메뉴 검증 · \(scenario) · 가짜 서비스"
        let content = NSHostingView(rootView: MenuContent(state: state, updater: updater).fixedSize())
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        var previousOutput = ""
        let observation = state.objectWillChange.sink {
            Task { @MainActor in
                let output = "status=\(state.status.rawValue) blocked=\(state.operationBlockReason != nil) pending=\(state.hasUnconfirmedWarmup) count=\(state.cycle.handledWindows) hold=\(state.cycle.recoveryHoldDayKey ?? "none")"
                if output != previousOutput {
                    print(output)
                    fflush(nil)
                    previousOutput = output
                }
                window.setContentSize(content.fittingSize)
            }
        }
        withExtendedLifetime((window, state, updater, observation)) { app.run() }
    }
}
