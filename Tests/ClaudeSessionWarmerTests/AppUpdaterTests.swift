import XCTest
@testable import ClaudeSessionWarmer

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testInstallationWaitsForWarmupAndResumesExactlyOnce() async throws {
        let suite = "AppUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = UpdateInspectionGate()
        let state = AppState(store: SettingsStore(defaults: defaults), startScheduler: false,
                             inspectClaude: { await gate.inspect($0) },
                             warmClaude: { _, _ in XCTFail("이미 활성인 테스트에서 전송 금지") })
        let updater = AppUpdater(state: state)
        var installs = 0
        XCTAssertFalse(updater.postponeInstallationIfWorking { installs += 1 })
        XCTAssertEqual(installs, 0)

        state.manualWarmup()
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.isWorking)
        XCTAssertTrue(updater.postponeInstallationIfWorking { installs += 1 })
        XCTAssertEqual(installs, 0)
        await gate.release()
        for _ in 0..<100 {
            if installs == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(updater.postponeInstallationIfWorking { installs += 1 })
        XCTAssertEqual(installs, 1)
    }
}

private actor UpdateInspectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func inspect(_ id: String) async -> Inspection {
        await withCheckedContinuation { continuation = $0 }
        return Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                          quota: QuotaWindow(active: true, resetsAt: Date().addingTimeInterval(18_000)),
                          operationID: id)
    }
    func release() { continuation?.resume(); continuation = nil }
}
