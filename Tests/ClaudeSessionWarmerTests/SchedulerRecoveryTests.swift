import AppKit
import XCTest
@testable import ClaudeSessionWarmer

@MainActor
final class SchedulerRecoveryTests: XCTestCase {
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

    func testFirstAttemptAndRetryDeadlinesRemainDistinct() async throws {
        for (started, offset, allowed) in [(false, 0.0, true), (false, 5.0, true),
                                           (false, 5.001, false), (true, 180.0, true),
                                           (true, 180.001, false)] {
            let f = Fixture(offset: offset)
            defer { f.cleanup() }
            let state = f.makeState()
            if started { state.markScheduledWindowStarted(f.event) }
            state.handle(f.event)
            try await finish(state)
            let count = await f.backend.inspections
            XCTAssertEqual(count, allowed ? 1 : 0, "started=\(started), offset=\(offset)")
            XCTAssertEqual(state.status, allowed ? .satisfied : .missed)
            XCTAssertEqual(state.cycle.handledWindows, 1)
        }
    }

    func testWakeBeforeRetryPreservesDateAndExpiryPreservesFirstFailure() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let state = f.makeState()
        state.markScheduledWindowStarted(f.event)
        state.handleTargetFailure(ClaudeServiceError.quotaUnavailable, event: f.event, at: f.target)
        let originalFailure = state.cycle.firstFailure
        let retry = try XCTUnwrap(state.nextEvent)
        XCTAssertEqual(retry.date, f.target.addingTimeInterval(30))
        f.clock.set(f.target.addingTimeInterval(20))
        state.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(state.nextEvent, retry)
        f.clock.set(f.target.addingTimeInterval(35))
        state.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(state.nextEvent?.date, f.clock.now())
        XCTAssertEqual(state.nextEvent?.targetAt, f.target)
        f.clock.set(f.target.addingTimeInterval(181))
        state.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.cycle.lastRecord?.message, originalFailure?.message)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        XCTAssertEqual(state.nextEvent?.targetAt, f.target.addingTimeInterval(18_000))
    }

    func testClockChangesAndMissedWakeKeepFallbackWithoutReopeningHandledWindow() async throws {
        let f = Fixture(offset: -3600)
        defer { f.cleanup() }
        let state = f.makeState()
        state.arm(f.event, at: f.target)
        f.clock.set(f.target.addingTimeInterval(-7200))
        state.reconcileSchedule(reason: "clock_changed")
        XCTAssertEqual(state.nextEvent?.date, f.target)
        f.clock.set(f.target.addingTimeInterval(181))
        state.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(state.status, .missed)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        XCTAssertEqual(state.nextEvent?.targetAt, f.target.addingTimeInterval(18_000))
        f.clock.set(f.target.addingTimeInterval(-60))
        state.reconcileSchedule(reason: "clock_changed")
        XCTAssertEqual(state.nextEvent?.windowNumber, 2)
        let count = await f.backend.inspections
        XCTAssertEqual(count, 0)
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
            XCTAssertEqual(count, 1)
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

    func testSleepDuringInactiveInspectionCannotSendAfterDeadline() async throws {
        let f = Fixture(hold: true, active: false)
        defer { f.cleanup() }
        let state = f.makeState()
        state.handle(f.event)
        try await waitForInspection(f.backend)
        f.clock.set(f.target.addingTimeInterval(181))
        state.reconcileSchedule(reason: "system_wake")
        await f.backend.release()
        try await finish(state)
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        XCTAssertEqual(state.nextEvent?.targetAt, f.target.addingTimeInterval(18_000))
        let count = await f.backend.inspections
        XCTAssertEqual(count, 1)
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
                        warmClaude: { _, _ in XCTFail("활성 상태 가짜 응답에서 CLI 호출 금지") },
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
    private let error: ClaudeServiceError?
    private let active: Bool
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
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                          quota: QuotaWindow(active: active, resetsAt: active ? reset : nil), operationID: id)
    }

    func release() { continuation?.resume(); continuation = nil }
}
