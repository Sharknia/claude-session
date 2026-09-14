import Foundation
import Sparkle

/// 최초 설치 승인 뒤에는 추가 확인 없이 설치·재시작한다. 나머지 UI는 Sparkle에 위임한다.
@MainActor
final class OneClickUpdateUserDriver: NSObject, SPUUserDriver {
    private let standard: SPUStandardUserDriver
    private(set) var installationApproved = false

    init(hostBundle: Bundle) {
        standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    func didChoose(_ choice: SPUUserUpdateChoice) {
        installationApproved = choice == .install
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installationApproved { reply(.install) }
        else { standard.showReady(toInstallAndRelaunch: reply) }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installationApproved = false
        standard.showUpdateFound(with: item, state: state) { [weak self] choice in
            self?.didChoose(choice)
            reply(choice)
        }
    }

    func showUpdateReleaseNotes(with data: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: data)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installationApproved = false
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installationApproved = false
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standard.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(length)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool,
                              retryTerminatingApplication retry: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: terminated, retryTerminatingApplication: retry)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        installationApproved = false
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        installationApproved = false
        standard.dismissUpdateInstallation()
    }

    func showUpdateInFocus() { standard.showUpdateInFocus() }
}
