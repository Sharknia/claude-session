import AppKit
import SwiftUI

@main
struct ClaudeSessionWarmerApp: App {
    @StateObject private var runtime = ApplicationRuntime()

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
            if let state = runtime.state, let updater = runtime.updater {
                MenuContent(state: state, updater: updater)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(runtime.startupMessage)
                    Button("응용 프로그램 폴더 열기") {
                        NSWorkspace.shared.selectFile(InstallationPolicy.applicationURL.path,
                                                      inFileViewerRootedAtPath: "/Applications")
                    }
                    Button("종료") { NSApplication.shared.terminate(nil) }
                }.padding().frame(width: 340)
            }
        } label: {
            Image(nsImage: menuBarIcon)
                .accessibilityLabel("Claude Session Warmer")
        }
        .menuBarExtraStyle(.window)
    }
}

/// AppState를 만들기 전까지 설정·로그인 항목·인증 저장소에 접근하지 않는다.
@MainActor
final class ApplicationRuntime: ObservableObject {
    let state: AppState?
    let updater: AppUpdater?
    let startupMessage: String
    private let ownership: ExecutionOwnership?
    private var launchObserver: NSObjectProtocol?

    init() {
        let url = Bundle.main.bundleURL
        var acquired: ExecutionOwnership?
        var message: String?
        if !InstallationPolicy.isCanonicalApp(url) {
            message = "응용 프로그램 폴더의 ClaudeSessionWarmer를 실행해 주세요. 현재 복사본에서는 예약을 시작하지 않습니다."
        } else {
            do {
                acquired = try ExecutionOwnership(directory: InstallationPolicy.dataDirectory)
                if !LegacyAppProcess.running().isEmpty {
                    message = "이전 버전이 실행 중입니다. 진행 중인 작업이 끝난 뒤 이전 앱을 종료하고 다시 실행해 주세요."
                }
            } catch ExecutionOwnership.Failure.alreadyRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: InstallationPolicy.bundleIdentifier)
                    .first { $0.processIdentifier != getpid() }?.activate()
                // 소유권을 얻지 못한 복사본은 상태 객체를 만들지 않고 즉시 종료한다.
                exit(0)
            } catch {
                message = "실행 잠금을 확보하지 못했습니다. 앱을 종료한 뒤 다시 실행해 주세요."
            }
        }
        ownership = acquired
        startupMessage = message ?? ""
        if message == nil {
            let state = AppState(executionCheck: {
                LegacyAppProcess.running().isEmpty ? nil : "이전 앱이 실행되어 예약을 중지했습니다. 이전 앱을 종료한 뒤 이 앱을 다시 실행해 주세요."
            })
            self.state = state
            updater = AppUpdater(state: state)
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak state] _ in
                Task { @MainActor in _ = state?.refreshExecutionPermission() }
            }
        } else {
            state = nil
            updater = nil
        }
        diagnosticLogCritical("app.execution_ownership", [
            "app_path": url.path, "pid": "\(getpid())",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "outcome": message == nil ? "owner" : "blocked"
        ])
    }
}
