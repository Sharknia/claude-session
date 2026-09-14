import Combine
import Foundation
import Sparkle

/// 업데이트 확인·다운로드·검증·설치 UI는 Sparkle의 기본 흐름을 사용한다.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    private let state: AppState
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []
    private var pendingInstall: (() -> Void)?

    init(state: AppState) {
        self.state = state
        super.init()
        state.$isWorking.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumePendingInstall() }
        }.store(in: &observations)
        // SwiftPM 테스트·CLI에는 배포용 Info.plist가 없으므로 업데이트 UI를 띄우지 않는다.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(state.$isWorking)
            .map { canCheck, working in canCheck && !working }
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .handleEvents(receiveOutput: { available in
                diagnosticLog("update.check_availability", ["available": "\(available)"])
            })
            .assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates, !state.isWorking else { return }
        diagnosticLog("update.check_requested")
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !state.isWorking else {
            throw NSError(domain: "ClaudeSessionWarmer.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "워밍이 끝난 뒤 업데이트를 확인해 주세요."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfWorking(installHandler)
    }

    func postponeInstallationIfWorking(_ installHandler: @escaping () -> Void) -> Bool {
        guard state.isWorking else { return false }
        pendingInstall = installHandler
        diagnosticLog("update.install_deferred", ["reason": "warmup_running"])
        return true
    }

    private func resumePendingInstall() {
        guard !state.isWorking, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        diagnosticLog("update.available", ["version": item.displayVersionString, "build": item.versionString])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        diagnosticLog("update.up_to_date")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        pendingInstall = nil
        let error = error as NSError
        diagnosticLog("update.aborted", ["domain": error.domain, "code": "\(error.code)"])
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        diagnosticLogCritical("update.relaunching")
    }
}
