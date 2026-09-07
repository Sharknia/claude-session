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
            QuotaWindow(active: true, resetsAt: target.addingTimeInterval(36_000))
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
        let counts = await backend.counts()
        XCTAssertEqual(counts.inspections, 4)
        XCTAssertEqual(counts.warmups, 2)
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
        XCTAssertEqual(state.status, .failed)
        let retry = try XCTUnwrap(state.nextEvent)
        let restarted = makeState(store, engine, retry.date, backend)
        restarted.handle(retry)
        try await finish(restarted)
        XCTAssertEqual(restarted.status, .satisfied)
        XCTAssertEqual(restarted.cycle.handledWindows, 1)
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
        XCTAssertEqual(state.cycle.handledWindows, 1)
        XCTAssertEqual(state.nextEvent?.windowNumber, 2)
        let counts = await backend.counts()
        XCTAssertEqual(counts.warmups, 0)
        XCTAssertEqual(counts.inspections, 1)
    }

    private func makeState(_ store: SettingsStore, _ engine: ScheduleEngine, _ now: Date, _ backend: FakeScheduledBackend) -> AppState {
        AppState(store: store, engine: engine, startScheduler: false,
                 clock: { now },
                 inspectScheduled: { try await backend.inspect($0) },
                 warmScheduled: { _, _ in try await backend.warm() })
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
