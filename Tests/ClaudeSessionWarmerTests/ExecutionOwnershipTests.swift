import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class ExecutionOwnershipTests: XCTestCase {
    func testOnlyCanonicalInstallationCanStart() {
        XCTAssertTrue(InstallationPolicy.isCanonicalApp(URL(fileURLWithPath: "/Applications/ClaudeSessionWarmer.app")))
        for path in ["/Users/test/Downloads/ClaudeSessionWarmer.app", "/Volumes/Installer/ClaudeSessionWarmer.app",
                     "/tmp/build/ClaudeSessionWarmer.app", "/Applications/Other.app"] {
            XCTAssertFalse(InstallationPolicy.isCanonicalApp(URL(fileURLWithPath: path)))
        }
    }

    func testLockReleaseAndIndependentUserDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: ExecutionOwnership? = try ExecutionOwnership(directory: root.appendingPathComponent("user1"))
        XCTAssertNotNil(owner)
        XCTAssertThrowsError(try ExecutionOwnership(directory: root.appendingPathComponent("user1")))
        let other = try ExecutionOwnership(directory: root.appendingPathComponent("user2"))
        withExtendedLifetime(other) { owner = nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("user1/execution.lock").path))
        let replacement = try ExecutionOwnership(directory: root.appendingPathComponent("user1"))
        withExtendedLifetime(replacement) {}
    }

    @MainActor
    func testBlockedExecutionDoesNotInspectWarmOrWrite() async throws {
        let defaults = MemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        let cycle = DailyCycle(lastWarmupTargetAt: Date(), lastWarmupAttemptAt: Date())
        store.saveDailyCycle(cycle)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let state = AppState(store: store, startScheduler: false, executionCheck: { "구버전 실행 중" },
                             inspectClaude: { _ in XCTFail("차단 후 인증 조회"); throw URLError(.cancelled) },
                             warmClaude: { _, _ in XCTFail("차단 후 워밍") })
        state.refreshSilently(force: true)
        state.manualWarmup(allowResend: true)
        state.connectClaude()
        state.reconcileSchedule(reason: "screen_unlocked")
        XCTAssertFalse(state.applySettings(firstWarmupDate: Date(), weekdays: [2], excludeKoreanHolidays: false))
        await Task.yield()
        XCTAssertEqual(state.operationBlockReason, "구버전 실행 중")
        XCTAssertNil(state.nextEvent)
        XCTAssertEqual(before, defaults.dictionaryRepresentation() as NSDictionary)
    }

    @MainActor
    func testConflictAppearingDuringInspectionPreventsSend() async throws {
        let conflict = ExecutionConflictFlag()
        let defaults = MemoryDefaults()
        let state = AppState(store: SettingsStore(defaults: defaults), startScheduler: false,
                             executionCheck: { conflict.blocked ? "구버전 실행 중" : nil },
                             inspectClaude: { id in
                                 await MainActor.run { conflict.blocked = true }
                                 return Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                                                   quota: QuotaWindow(active: false), operationID: id)
                             }, warmClaude: { _, _ in XCTFail("충돌 감지 뒤 전송") })
        state.manualWarmup()
        for _ in 0..<100 where state.isWorking {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.operationBlockReason, "구버전 실행 중")
        XCTAssertNil(defaults.data(forKey: "quotaCache"))
        XCTAssertNil(state.cycle.lastWarmupAttemptAt)
    }
}

@MainActor
private final class ExecutionConflictFlag {
    var blocked = false
}
