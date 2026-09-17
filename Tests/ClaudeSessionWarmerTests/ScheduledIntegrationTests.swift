import XCTest
@testable import ClaudeSessionWarmer

@MainActor
final class ScheduledIntegrationTests: XCTestCase {
    func testScheduledActivationPersistsAcrossRestartAndRunsNextWindowOnce() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        let backend = FakeScheduledBackend(quotas: [
            QuotaWindow(active: false),
            QuotaWindow(active: true, resetsAt: target.addingTimeInterval(18_000)),
            QuotaWindow(active: false),
            QuotaWindow(active: true, resetsAt: target.addingTimeInterval(36_000)),
            QuotaWindow(active: false),
            QuotaWindow(active: true, resetsAt: target.addingTimeInterval(54_000))
        ])
        let state = makeState(store, engine, target, backend)
        let first = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
        state.handle(first)
        try await finish(state)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(store.loadDailyCycle().handledWindows, 1)
        let next = try XCTUnwrap(state.nextEvent)
        XCTAssertEqual(next.windowNumber, 2)
        XCTAssertEqual(next.targetAt, target.addingTimeInterval(18_000))

        // 이전 프로세스의 메모리 없이 저장된 주기에서 두 번째 예약을 이어간다.
        let restarted = makeState(store, engine, next.targetAt, backend)
        restarted.handle(first) // 늦게 도착한 이전 콜백은 무시해야 한다.
        restarted.handle(next)
        try await finish(restarted)
        restarted.handle(next)
        XCTAssertEqual(restarted.status, .succeeded)
        XCTAssertEqual(store.loadDailyCycle().handledWindows, 2)
        XCTAssertEqual(restarted.nextEvent?.windowNumber, 3)
        XCTAssertEqual(restarted.nextEvent?.targetAt, target.addingTimeInterval(36_000))
        let third = try XCTUnwrap(restarted.nextEvent)
        let final = makeState(store, engine, third.targetAt, backend)
        final.handle(third)
        try await finish(final)
        XCTAssertEqual(final.cycle.handledWindows, 3)
        XCTAssertEqual(final.nextEvent?.dayKey, "2026-09-09")
        final.handle(ScheduledEvent(date: third.targetAt, targetAt: third.targetAt,
                                    dayKey: third.dayKey, windowNumber: 4))
        XCTAssertFalse(final.isWorking)
        let counts = await backend.counts()
        XCTAssertEqual(counts.inspections, 6)
        XCTAssertEqual(counts.warmups, 3)
    }

    func testWarmupTimeoutThenActiveQuotaNeverResendsPrompt() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        let backend = FakeScheduledBackend(quotas: [
            QuotaWindow(active: false),
            QuotaWindow(active: true, resetsAt: target.addingTimeInterval(18_000))
        ], warmupError: .warmupTimedOut)
        let state = makeState(store, engine, target, backend)
        let first = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
        state.handle(first)
        try await finish(state)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 1)
    }

    func testAuthenticationRejectionDoesNotSpawnWarmup() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        let backend = FakeScheduledBackend(quotas: [], inspectionError: .oauthRefreshFailed)
        let state = makeState(store, engine, target, backend)
        state.handle(ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1))
        try await finish(state)
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.cycle.handledWindows, 0)
        XCTAssertEqual(state.nextEvent?.dayKey, "2026-09-09")
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 0)
        XCTAssertEqual(counts.inspections, 1)
    }

    func testManualAndScheduledWaitForActivationWithoutFailureOrStaleQuota() async throws {
        for manual in [false, true] {
            let (store, engine, target, cleanup) = fixture()
            defer { cleanup() }
            store.saveQuotaCache(QuotaCache(quota: QuotaWindow(active: true, usedPercent: 100, resetsAt: target), fetchedAt: Date()))
            let backend = FakeScheduledBackend(quotas: [
                QuotaWindow(active: false, usedPercent: 0),
                QuotaWindow(active: false, usedPercent: 0),
                QuotaWindow(active: false, usedPercent: 0),
                QuotaWindow(active: true, usedPercent: 0, resetsAt: target.addingTimeInterval(18_000))
            ])
            let probe = ConfirmationProbe()
            let state = AppState(store: store, engine: engine, startScheduler: false,
                clock: { target }, inspectClaude: { try await backend.inspect($0) },
                warmClaude: { _, _ in try await backend.warm() },
                confirmationSleep: { await probe.capture($0) })
            probe.state = state
            if manual { state.manualWarmup() }
            else { state.handle(ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)) }
            try await finish(state)
            XCTAssertEqual(probe.delays, [.seconds(5), .seconds(10), .seconds(15)])
            XCTAssertEqual(probe.statuses, [.checking, .checking, .checking])
            XCTAssertEqual(probe.usedPercent, [0, 0, 0])
            XCTAssertEqual(state.status, .succeeded)
            XCTAssertEqual(state.statusMessage, "세션 활성화를 확인했습니다.")
            let counts = await backend.counts()
            XCTAssertEqual(counts.warmups, 1)
            XCTAssertEqual(counts.inspections, 4)
        }
    }

    func testManualAndScheduledAlreadyActiveUseSameMessageAndNeverWarm() async throws {
        for manual in [false, true] {
            let (store, engine, target, cleanup) = fixture()
            defer { cleanup() }
            let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: true, resetsAt: target.addingTimeInterval(18_000))])
            let state = makeState(store, engine, target, backend)
            if manual { state.manualWarmup() }
            else { state.handle(ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)) }
            try await finish(state)
            XCTAssertEqual(state.status, .satisfied)
            XCTAssertEqual(state.statusMessage, "이미 세션이 활성화되었습니다.")
            let counts = await backend.counts()
            XCTAssertEqual(counts.warmups, 0)
            XCTAssertEqual(counts.inspections, 1)
        }
    }

    func testConfirmationExhaustionIsBoundedAndRestartDoesNotResend() async throws {
        for manual in [false, true] {
            let (store, engine, target, cleanup) = fixture()
            defer { cleanup() }
            let backend = FakeScheduledBackend(quotas:
                Array(repeating: QuotaWindow(active: false), count: 6)
                + [QuotaWindow(active: true, resetsAt: target.addingTimeInterval(18_000))])
            let probe = ConfirmationProbe()
            let state = AppState(store: store, engine: engine, startScheduler: false,
                clock: { target }, inspectClaude: { try await backend.inspect($0) },
                warmClaude: { _, _ in try await backend.warm() },
                confirmationSleep: { await probe.capture($0) })
            probe.state = state
            if manual { state.manualWarmup() }
            else { state.handle(ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)) }
            try await finish(state)
            XCTAssertEqual(probe.delays, [.seconds(5), .seconds(10), .seconds(15), .seconds(15), .seconds(15)])
            XCTAssertTrue(probe.statuses.allSatisfy { $0 == .checking })
            XCTAssertEqual(state.status, .checking)
            let restarted = makeState(store, engine, target.addingTimeInterval(30), backend)
            if manual { restarted.manualWarmup() }
            else { restarted.handle(try XCTUnwrap(state.nextEvent)) }
            try await finish(restarted)
            XCTAssertEqual(restarted.status, .satisfied)
            let counts = await backend.counts()
            XCTAssertEqual(counts.warmups, 1)
            XCTAssertEqual(counts.inspections, 7)
        }
    }

    func testRecentManualAttemptOnlyChecksQuotaWithoutAnotherWarmup() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        store.saveDailyCycle(DailyCycle(lastWarmupTargetAt: target.addingTimeInterval(-30)))
        let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: false),
            QuotaWindow(active: true, resetsAt: target.addingTimeInterval(18_000))])
        let state = makeState(store, engine, target, backend)
        state.manualWarmup()
        try await finish(state)
        XCTAssertEqual(state.status, .satisfied)
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 0)
        XCTAssertEqual(counts.inspections, 2)
    }

    func testIncidentDelayAndManyMissedHoursWarmOnlyOnceUsingActualReset() async throws {
        for delay in [147.0, 10_800, 36_000] {
            let (store, engine, target, cleanup) = fixture()
            defer { cleanup() }
            let now = target.addingTimeInterval(delay)
            let actualReset = now.addingTimeInterval(18_000)
            let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: false),
                QuotaWindow(active: true, resetsAt: actualReset)])
            let state = makeState(store, engine, now, backend)
            state.reconcileSchedule(reason: "startup")
            let due = try XCTUnwrap(state.nextEvent)
            let timerID = try XCTUnwrap(state.scheduledTimerID)
            XCTAssertEqual(due.targetAt, target)
            state.receiveTimerCallback(due, id: timerID, callbackAt: now)
            try await finish(state)
            XCTAssertEqual(state.status, .succeeded)
            XCTAssertEqual(state.cycle.handledWindows, 1)
            XCTAssertEqual(state.nextEvent?.targetAt, actualReset)
            let counts = await backend.counts()
            XCTAssertEqual(counts.warmups, 1)
            XCTAssertEqual(counts.inspections, 2)
        }
    }

    func testUnconfirmedTransmissionSurvivesNextDayAndManualRequests() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: target), lastWarmupTargetAt: target,
                                      lastWarmupAttemptAt: target.addingTimeInterval(147)))
        let now = target.addingTimeInterval(86_400 + 3600)
        let backend = FakeScheduledBackend(quotas: Array(repeating: QuotaWindow(active: false), count: 12))
        let state = makeState(store, engine, now, backend)
        state.reconcileSchedule(reason: "startup")
        state.handle(try XCTUnwrap(state.nextEvent))
        try await finish(state)
        let restarted = makeState(store, engine, now, backend)
        restarted.manualWarmup()
        try await finish(restarted)
        XCTAssertTrue(restarted.hasUnconfirmedWarmup)
        XCTAssertEqual(restarted.cycle.handledWindows, 0)
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 0)
    }

    func testExplicitResendRechecksQuotaAndAllowsOnlyOneNewWarmup() async throws {
        for active in [false, true] {
            let (store, engine, target, cleanup) = fixture()
            defer { cleanup() }
            store.saveDailyCycle(DailyCycle(lastWarmupTargetAt: target.addingTimeInterval(-3600)))
            let reset = target.addingTimeInterval(18_000)
            let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: active, resetsAt: active ? reset : nil),
                QuotaWindow(active: true, resetsAt: reset)])
            let state = makeState(store, engine, target, backend)
            state.manualWarmup(allowResend: true)
            try await finish(state)
            XCTAssertFalse(state.hasUnconfirmedWarmup)
            XCTAssertEqual(state.cycle.handledWindows, 1)
            let counts = await backend.counts()
            XCTAssertEqual(counts.warmups, active ? 0 : 1)
        }
    }

    func testSameActiveWindowWithFractionalResetCorrectionIsNotCountedTwice() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        let reset = target.addingTimeInterval(18_000)
        // 재조회 대상이 남았더라도 확인된 같은 창을 새 완료로 집계하지 않는다.
        store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: target), handledWindows: 1,
                                      nextResetAt: target, lastConfirmedResetAt: reset))
        let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: true, resetsAt: reset.addingTimeInterval(0.4))])
        let state = makeState(store, engine, target, backend)
        state.handle(ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 2))
        try await finish(state)
        XCTAssertEqual(state.cycle.handledWindows, 1)
        XCTAssertEqual(state.nextEvent?.targetAt, reset.addingTimeInterval(0.4))
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 0)
    }

    func testOutsideScheduleManualWarmupDoesNotStartAutomaticChain() async throws {
        let (store, engine, target, cleanup) = fixture()
        defer { cleanup() }
        let now = target.addingTimeInterval(-3600)
        let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: false),
            QuotaWindow(active: true, resetsAt: now.addingTimeInterval(18_000))])
        let state = makeState(store, engine, now, backend)
        state.manualWarmup()
        try await finish(state)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(state.cycle.handledWindows, 0)
        XCTAssertNil(state.nextEvent)
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 1)
    }

    func testExpiredActiveResponseAndMissingResetDoNotTriggerWarmup() async throws {
        for reset in [Optional<Date>.none, targetForExpiredQuota()] {
            let (store, engine, target, cleanup) = fixture()
            defer { cleanup() }
            let backend = FakeScheduledBackend(quotas: [QuotaWindow(active: true, resetsAt: reset)])
            let state = makeState(store, engine, target, backend)
            state.handle(ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1))
            try await finish(state)
            XCTAssertEqual(state.cycle.handledWindows, 0)
            let counts = await backend.counts()
            XCTAssertEqual(counts.warmups, 0)
        }
    }

    private func targetForExpiredQuota() -> Date {
        ISO8601DateFormatter().date(from: "2026-09-07T20:59:00Z")!
    }

    private func makeState(_ store: SettingsStore, _ engine: ScheduleEngine, _ now: Date, _ backend: FakeScheduledBackend) -> AppState {
        AppState(store: store, engine: engine, startScheduler: false,
                 clock: { now },
                 inspectClaude: { try await backend.inspect($0) },
                 warmClaude: { _, _ in try await backend.warm() },
                 confirmationSleep: { _ in })
    }

    private func finish(_ state: AppState) async throws {
        for _ in 0..<100 {
            if !state.isWorking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("예약 처리가 종료되지 않음")
    }

    private func fixture() -> (SettingsStore, ScheduleEngine, Date, () -> Void) {
        let suite = "ScheduledIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let engine = ScheduleEngine(calendar: calendar)
        let target = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 6))!
        store.saveSettings(ScheduleSettings(firstWarmupMinutes: 360, weekdays: Set(1...7), excludeKoreanHolidays: false))
        return (store, engine, target, { defaults.removePersistentDomain(forName: suite) })
    }
}

private actor FakeScheduledBackend {
    private var quotas: [QuotaWindow]
    private let warmupError: ClaudeServiceError?
    private let inspectionError: ClaudeServiceError?
    private var inspections = 0
    private var warmups = 0

    init(quotas: [QuotaWindow], warmupError: ClaudeServiceError? = nil, inspectionError: ClaudeServiceError? = nil) {
        self.quotas = quotas
        self.warmupError = warmupError
        self.inspectionError = inspectionError
    }

    func inspect(_ operationID: String) throws -> Inspection {
        inspections += 1
        if let inspectionError { throw inspectionError }
        guard !quotas.isEmpty else { throw ClaudeServiceError.quotaUnavailable }
        return Inspection(cliURL: URL(fileURLWithPath: "/unused-fake-cli"), quota: quotas.removeFirst(), operationID: operationID)
    }

    func warm() throws {
        warmups += 1
        if let warmupError { throw warmupError }
    }

    func counts() -> (inspections: Int, warmups: Int) { (inspections, warmups) }
}

@MainActor
private final class ConfirmationProbe {
    weak var state: AppState?
    var delays: [Duration] = []
    var statuses: [WarmupStatus] = []
    var usedPercent: [Double?] = []

    func capture(_ delay: Duration) {
        delays.append(delay)
        if let state {
            statuses.append(state.status)
            usedPercent.append(state.currentQuota?.usedPercent)
        }
    }
}
