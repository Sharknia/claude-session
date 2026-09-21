import AppKit
import Security
import XCTest
@testable import ClaudeSessionWarmer

@MainActor
final class SchedulerRecoveryTests: XCTestCase {
    func testKeychainFailureKeepsTodaysTargetAfterFastRetriesAndRecoversOnUnlock() async throws {
        let f = Fixture(error: .credentialsUnavailable(errSecAuthFailed), active: false)
        defer { f.cleanup() }
        var state = f.makeState()
        state.handle(f.event)
        try await finish(state)
        for _ in 0..<3 {
            f.clock.set(try XCTUnwrap(state.nextEvent?.date))
            state.handle(try XCTUnwrap(state.nextEvent))
            try await finish(state)
        }
        XCTAssertEqual(state.cycle.firstFailure?.attempts, 4)
        XCTAssertEqual(state.nextEvent?.targetAt, f.target)
        XCTAssertEqual(state.nextEvent?.date, f.clock.now().addingTimeInterval(300))
        XCTAssertEqual(state.cycle.handledWindows, 0)
        let failedWarmups = await f.backend.warmups
        XCTAssertEqual(failedWarmups, 0)

        state = f.makeState() // 저장된 복구 상태는 재시작 뒤에도 유지한다.
        f.clock.set(f.clock.now().addingTimeInterval(10))
        await f.backend.clearError()
        state.reconcileSchedule(reason: "screen_unlocked")
        XCTAssertEqual(state.nextEvent?.date, f.clock.now())
        let event = try XCTUnwrap(state.nextEvent)
        let id = try XCTUnwrap(state.scheduledTimerID)
        state.receiveTimerCallback(event, id: id, callbackAt: f.clock.now())
        try await finish(state)
        state.receiveTimerCallback(event, id: id, callbackAt: f.clock.now())
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertNil(state.cycle.firstFailure)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        let warmups = await f.backend.warmups
        XCTAssertEqual(warmups, 1)
    }

    func testWeekendAndRepeatedWakeKeepMondayTarget() throws {
        let f = Fixture(offset: -62 * 3600)
        defer { f.cleanup() }
        f.store.saveDailyCycle(DailyCycle(dayKey: "2026-09-11", handledWindows: 3))
        let state = f.makeState()
        state.reconcileSchedule(reason: "test_start")
        XCTAssertEqual(state.nextEvent?.targetAt, f.target)
        var id = state.scheduledTimerID
        for offset in [-40 * 3600.0, -12 * 3600.0, -60.0] {
            f.clock.set(f.target.addingTimeInterval(offset))
            state.reconcileSchedule(reason: "system_wake")
            XCTAssertEqual(state.nextEvent?.date, f.target)
            XCTAssertEqual(state.nextEvent?.targetAt, f.target)
            XCTAssertNotEqual(state.scheduledTimerID, id)
            id = state.scheduledTimerID
        }
        XCTAssertEqual(state.cycle.handledWindows, 3) // 금요일 기록은 월요일 실행 전에 바꾸지 않는다.
    }

    func testReplacedCallbacksNeverExecuteIncludingSameDate() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let state = f.makeState()
        state.arm(f.event, at: f.target)
        let oldID = try XCTUnwrap(state.scheduledTimerID)
        state.reconcileSchedule(reason: "system_wake")
        let currentID = try XCTUnwrap(state.scheduledTimerID)
        XCTAssertNotEqual(oldID, currentID)
        state.receiveTimerCallback(f.event, id: oldID, callbackAt: f.target)
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.cycle.handledWindows, 0)
        state.receiveTimerCallback(f.event, id: currentID, callbackAt: f.target)
        state.receiveTimerCallback(f.event, id: currentID, callbackAt: f.target)
        try await finish(state)
        let count = await f.backend.inspections
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state.cycle.handledWindows, 1)
    }

    func testEarlyFirstAndRetryCallbacksWaitUntilTheirOwnDate() async throws {
        for started in [false, true] {
            let f = Fixture(offset: -0.1)
            defer { f.cleanup() }
            let state = f.makeState()
            let event: ScheduledEvent
            if started {
                state.markScheduledWindowStarted(f.event)
                event = ScheduledEvent(date: f.target.addingTimeInterval(30), targetAt: f.target,
                                       dayKey: f.event.dayKey, windowNumber: 1)
                f.clock.set(event.date.addingTimeInterval(-0.1))
            } else { event = f.event }
            state.handle(event)
            XCTAssertFalse(state.isWorking)
            XCTAssertEqual(state.nextEvent?.date, event.date)
            XCTAssertEqual(state.nextEvent?.targetAt, f.target)
            let count = await f.backend.inspections
            XCTAssertEqual(count, 0)
        }
    }

    func testDelayedCallbacksExecuteWithoutGraceDeadline() async throws {
        for offset in [0.0, 5.0, 5.001, 147.0, 180.001, 10_800.0] {
            let f = Fixture(offset: offset, active: false)
            defer { f.cleanup() }
            let state = f.makeState()
            state.handle(f.event)
            try await finish(state)
            XCTAssertEqual(state.status, .succeeded, "offset=\(offset)")
            XCTAssertEqual(state.cycle.handledWindows, 1)
            let warmups = await f.backend.warmups
            XCTAssertEqual(warmups, 1)
        }
    }

    func testWakeBeforeRetryAndRestartPreserveBackoff() {
        let f = Fixture()
        defer { f.cleanup() }
        let state = f.makeState()
        state.markScheduledWindowStarted(f.event)
        state.handleTargetFailure(ClaudeServiceError.quotaUnavailable, event: f.event, at: f.target)
        let originalFailure = state.cycle.firstFailure
        f.clock.set(f.target.addingTimeInterval(20))
        let restarted = f.makeState()
        restarted.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(restarted.nextEvent?.date, f.target.addingTimeInterval(30))
        XCTAssertEqual(restarted.cycle.firstFailure, originalFailure)
        f.clock.set(f.target.addingTimeInterval(181))
        restarted.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(restarted.nextEvent?.date, f.clock.now())
        XCTAssertEqual(restarted.nextEvent?.targetAt, f.target)
        XCTAssertEqual(restarted.cycle.handledWindows, 0)
    }

    func testClockChangesKeepDueTargetAndNeverRepeatCompletedWindow() async throws {
        let f = Fixture(offset: -3600)
        defer { f.cleanup() }
        let state = f.makeState()
        state.arm(f.event, at: f.target)
        f.clock.set(f.target.addingTimeInterval(-7200))
        state.reconcileSchedule(reason: "clock_changed")
        XCTAssertEqual(state.nextEvent?.date, f.target)
        f.clock.set(f.target.addingTimeInterval(181))
        state.reconcileSchedule(reason: "system_wake")
        state.handle(try XCTUnwrap(state.nextEvent))
        try await finish(state)
        XCTAssertEqual(state.status, .satisfied)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        f.clock.set(f.target.addingTimeInterval(-60))
        state.reconcileSchedule(reason: "clock_changed")
        state.handle(f.event)
        XCTAssertEqual(state.nextEvent?.windowNumber, 2)
        let count = await f.backend.inspections
        XCTAssertEqual(count, 1)
    }

    func testWakeDuringScheduledAndManualWorkDefersReconciliationUntilResult() async throws {
        for manual in [false, true] {
            let f = Fixture(hold: true)
            defer { f.cleanup() }
            if manual {
                f.store.saveDailyCycle(DailyCycle(dayKey: "2026-09-14", handledWindows: 1, nextResetAt: f.target))
            }
            let state = f.makeState()
            state.arm(f.event, at: f.target)
            if manual { state.manualWarmup() } else { state.handle(f.event) }
            try await waitForInspection(f.backend)
            let cycleBeforeWake = state.cycle
            f.clock.set(f.target.addingTimeInterval(240))
            for _ in 0..<3 { state.reconcileSchedule(reason: "system_wake") }
            XCTAssertTrue(state.isWorking)
            XCTAssertNil(state.scheduledTimerID)
            XCTAssertEqual(state.cycle, cycleBeforeWake)
            await f.backend.release()
            try await finish(state)
            XCTAssertEqual(state.status, .satisfied)
            XCTAssertEqual(state.cycle.handledWindows, manual ? 2 : 1)
            XCTAssertEqual(state.nextEvent?.targetAt, f.target.addingTimeInterval(18_000))
            XCTAssertNotNil(state.scheduledTimerID)
            let count = await f.backend.inspections
            XCTAssertEqual(count, 2)
        }
    }

    func testSettingsReplacementDuringWorkDiscardsOldCallbackAfterFailure() async throws {
        let f = Fixture(hold: true, error: .quotaUnavailable)
        defer { f.cleanup() }
        let state = f.makeState()
        state.arm(f.event, at: f.target)
        let oldID = try XCTUnwrap(state.scheduledTimerID)
        state.handle(f.event)
        try await waitForInspection(f.backend)
        XCTAssertTrue(state.applySettings(firstWarmupDate: f.target, weekdays: [3],
                                          excludeKoreanHolidays: false, launchAtLogin: false))
        state.reconcileSchedule(reason: "system_wake")
        await f.backend.release()
        try await finish(state)
        state.receiveTimerCallback(f.event, id: oldID, callbackAt: f.target)
        XCTAssertFalse(state.isWorking)
        let count = await f.backend.inspections
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state.nextEvent?.dayKey, "2026-09-15")
    }

    func testSleepDuringInactiveInspectionRefreshesBeforeSending() async throws {
        let f = Fixture(hold: true, active: false)
        defer { f.cleanup() }
        let state = f.makeState()
        state.handle(f.event)
        try await waitForInspection(f.backend)
        f.clock.set(f.target.addingTimeInterval(181))
        state.reconcileSchedule(reason: "system_wake")
        await f.backend.release()
        try await finish(state)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        let count = await f.backend.inspections
        let warmups = await f.backend.warmups
        XCTAssertEqual(count, 3) // 잠자기 전 응답, 재조회, 전송 후 확인
        XCTAssertEqual(warmups, 1)
    }

    func testSettingsChangeDuringTransientFailureKeepsStillEligibleRetryDate() async throws {
        let f = Fixture(hold: true, error: .quotaUnavailable)
        defer { f.cleanup() }
        let state = f.makeState()
        state.handle(f.event)
        try await waitForInspection(f.backend)
        XCTAssertTrue(state.applySettings(firstWarmupDate: f.target, weekdays: [2, 3, 4, 5, 6],
                                          excludeKoreanHolidays: true, launchAtLogin: false))
        state.reconcileSchedule(reason: "system_wake")
        await f.backend.release()
        try await finish(state)
        XCTAssertEqual(state.nextEvent?.date, f.target.addingTimeInterval(30))
        XCTAssertEqual(state.nextEvent?.targetAt, f.target)
        XCTAssertEqual(state.cycle.handledWindows, 0)
        XCTAssertNotNil(state.cycle.firstFailure)
    }

    func testDateChangeDuringInspectionDefersToTodaysFirstWithoutSendingOldWork() async throws {
        let f = Fixture(hold: true, active: false)
        defer { f.cleanup() }
        let state = f.makeState()
        state.handle(f.event)
        try await waitForInspection(f.backend)
        f.clock.set(f.target.addingTimeInterval(86_400 + 3600))
        state.reconcileSchedule(reason: "system_wake")
        await f.backend.release()
        try await finish(state)
        XCTAssertEqual(state.nextEvent?.dayKey, "2026-09-15")
        XCTAssertEqual(state.nextEvent?.targetAt, f.target.addingTimeInterval(86_400))
        let warmups = await f.backend.warmups
        XCTAssertEqual(warmups, 0)
        XCTAssertEqual(state.cycle.handledWindows, 0)
    }

    private func finish(_ state: AppState) async throws {
        for _ in 0..<100 {
            if !state.isWorking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("예약 작업 종료 시간 초과")
    }

    private func waitForInspection(_ backend: RecoveryBackend) async throws {
        for _ in 0..<100 {
            if await backend.waiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("가짜 조회 시작 시간 초과")
    }
}

@MainActor
private struct Fixture {
    let target = ISO8601DateFormatter().date(from: "2026-09-13T21:00:00Z")!
    let suite = "SchedulerRecoveryTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: SettingsStore
    let engine: ScheduleEngine
    let clock: RecoveryClock
    let backend: RecoveryBackend

    var event: ScheduledEvent {
        ScheduledEvent(date: target, targetAt: target, dayKey: "2026-09-14", windowNumber: 1)
    }

    init(offset: TimeInterval = 0, hold: Bool = false, error: ClaudeServiceError? = nil, active: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        store = SettingsStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        engine = ScheduleEngine(calendar: calendar)
        clock = RecoveryClock(target.addingTimeInterval(offset))
        backend = RecoveryBackend(reset: target.addingTimeInterval(18_000), hold: hold, error: error, active: active)
        store.saveSettings(ScheduleSettings(firstWarmupMinutes: 360, excludeKoreanHolidays: false))
        store.saveDailyCycle(DailyCycle(dayKey: "2026-09-14"))
    }

    func makeState() -> AppState {
        let clock = clock, backend = backend
        return AppState(store: store, engine: engine, startScheduler: false, clock: { clock.now() },
                        inspectClaude: { try await backend.inspect($0) },
                        warmClaude: { _, _ in await backend.warm() },
                        confirmationSleep: { _ in })
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

private actor RecoveryBackend {
    private let reset: Date
    private let hold: Bool
    private var error: ClaudeServiceError?
    private var active: Bool
    private(set) var warmups = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var inspections = 0
    var waiting: Bool { continuation != nil }

    init(reset: Date, hold: Bool, error: ClaudeServiceError?, active: Bool) {
        self.reset = reset
        self.hold = hold
        self.error = error
        self.active = active
    }

    func inspect(_ id: String) async throws -> Inspection {
        inspections += 1
        if hold && inspections == 1 { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                          quota: QuotaWindow(active: active, resetsAt: active ? reset : nil), operationID: id)
    }

    func warm() { warmups += 1; active = true }

    func release() { continuation?.resume(); continuation = nil }
    func clearError() { error = nil }
}
