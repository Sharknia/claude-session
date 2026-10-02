import Foundation
import IOKit
import XCTest
@testable import ClaudeSessionWarmer

/// 테스트용 가짜 어서션. 실제 IOKit을 호출하지 않는다.
@MainActor
final class FakeIdleSleepAssertion: IdleSleepAssertionHolding {
    private(set) var isHeld = false
    var nextAcquireResult: IOReturn = kIOReturnSuccess
    /// 일어난 순서대로 "acquire", "acquire_failed", "release".
    private(set) var transitions: [String] = []
    /// 전이가 기록된 직후 불린다. 그 순간의 AppState 상태를 관찰할 때 쓴다.
    var onTransition: ((String) -> Void)?

    func acquire() -> IOReturn {
        if isHeld { return kIOReturnSuccess }
        guard nextAcquireResult == kIOReturnSuccess else {
            record("acquire_failed")
            return nextAcquireResult
        }
        isHeld = true
        record("acquire")
        return kIOReturnSuccess
    }

    @discardableResult
    func release() -> IOReturn {
        guard isHeld else { return kIOReturnSuccess }
        isHeld = false
        record("release")
        return kIOReturnSuccess
    }

    private func record(_ name: String) {
        transitions.append(name)
        onTransition?(name)
    }
}

/// 테스트용 가짜 전원. `{ power.isOnAC }` 클로저로 주입한다.
final class FakePowerSource: @unchecked Sendable {
    var isOnAC = true
}

/// 테스트가 직접 옮기는 가짜 시계.
final class SleepTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

/// 조회·로그인·워밍을 모두 대신하는 가짜 백엔드. 브라우저·네트워크·Keychain을 쓰지 않는다.
actor SleepTestBackend {
    private let reset: Date
    private var error: ClaudeServiceError?
    private var active: Bool
    private(set) var inspections = 0
    private(set) var logins = 0
    private(set) var warmups = 0

    init(reset: Date, error: ClaudeServiceError?, active: Bool) {
        self.reset = reset
        self.error = error
        self.active = active
    }

    private func currentInspection(_ operationID: String) -> Inspection {
        Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                   quota: QuotaWindow(active: active, resetsAt: active ? reset : nil),
                   operationID: operationID)
    }

    func inspect(_ operationID: String) throws -> Inspection {
        inspections += 1
        if let error { throw error }
        return currentInspection(operationID)
    }

    func login() -> Inspection {
        logins += 1
        return currentInspection("fake-login")
    }

    func warm() {
        warmups += 1
        active = true
    }
}

/// `executionCheck`가 돌려줄 차단 사유. nil이면 차단하지 않는다.
@MainActor
final class SleepTestBlock {
    var reason: String?
}

/// 2026-09-14(월) 06:00 KST 첫 예약을 기준으로 한 공용 시험 환경.
@MainActor
struct SleepPreventionFixture {
    /// 첫 예약 시각. 2026-09-14 06:00 KST.
    let target = ISO8601DateFormatter().date(from: "2026-09-13T21:00:00Z")!
    let defaults = MemoryDefaults()
    let store: SettingsStore
    let engine: ScheduleEngine
    let clock: SleepTestClock
    let backend: SleepTestBackend
    let assertion = FakeIdleSleepAssertion()
    let power = FakePowerSource()
    let block = SleepTestBlock()

    /// 첫 예약 이벤트.
    var event: ScheduledEvent {
        ScheduledEvent(date: target, targetAt: target, dayKey: "2026-09-14", windowNumber: 1)
    }

    /// 워밍 뒤 확인되는 실제 리셋 시각. 같은 날 11:00 KST.
    var reset: Date { target.addingTimeInterval(18_000) }

    /// - Parameters:
    ///   - offset: 시계의 시작 시각을 첫 예약 기준 초 단위로 정한다. -1860이면 05:29다.
    ///   - error: 조회가 던질 오류. nil이면 조회가 성공한다.
    ///   - active: 조회 시 사용량 창이 이미 활성인가. false면 워밍 뒤 활성으로 바뀐다.
    init(mode: SleepPreventionMode, offset: TimeInterval = 0, error: ClaudeServiceError? = nil,
         active: Bool = false, onAC: Bool = true) {
        store = SettingsStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        engine = ScheduleEngine(calendar: calendar)
        clock = SleepTestClock(target.addingTimeInterval(offset))
        backend = SleepTestBackend(reset: target.addingTimeInterval(18_000), error: error, active: active)
        power.isOnAC = onAC
        store.saveSettings(ScheduleSettings(firstWarmupMinutes: 360, excludeKoreanHolidays: false,
                                            sleepPrevention: mode))
        store.saveDailyCycle(DailyCycle(dayKey: "2026-09-14"))
    }

    /// 이 파일의 모든 테스트는 이 함수로만 AppState를 만든다.
    /// 조회·로그인·워밍·어서션·전원을 전부 가짜로 주입하고, 가짜 시계이므로 스케줄러 타이머는 켜지 않는다.
    /// `startScheduler: true`는 차단 상태 시작 경로 검증 전용이며, 실제 시계(`Date()`)와만 쓴다.
    func makeState(store storeOverride: SettingsStore? = nil, startScheduler: Bool = false) -> AppState {
        let clock = clock, backend = backend, power = power, block = block
        let stateClock: @Sendable () -> Date
        if startScheduler {
            stateClock = { Date() }
        } else {
            stateClock = { clock.now() }
        }
        return AppState(
            store: storeOverride ?? store,
            engine: engine,
            startScheduler: startScheduler,
            executionCheck: { block.reason },
            clock: stateClock,
            inspectClaude: { try await backend.inspect($0) },
            loginClaude: { await backend.login() },
            warmClaude: { _, _ in await backend.warm() },
            sleepAssertion: assertion,
            isOnACPower: { power.isOnAC },
            confirmationSleep: { _ in }
        )
    }
}

@MainActor
final class SleepPreventionTests: XCTestCase {
    func testInitDoesNotTouchAssertionWhenOff() {
        let f = SleepPreventionFixture(mode: .off, offset: -10 * 60)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup")
        state.reevaluateSleepPrevention(trigger: "lead_time")

        XCTAssertEqual(state.nextEvent?.date, f.target)
        XCTAssertEqual(f.assertion.transitions, [])
        XCTAssertFalse(f.assertion.isHeld)
    }

    func testAlwaysOnACAcquiresAtStartupWithoutAnySchedule() {
        let f = SleepPreventionFixture(mode: .always, offset: -4 * 3600, onAC: true)
        let state = f.makeState()

        // startScheduler: false라 일정이 아직 없다. 그래도 `startup` 재평가가 반영한다.
        XCTAssertNil(state.nextEvent)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
        XCTAssertTrue(f.assertion.isHeld)
    }

    func testStartupDoesNotAcquireOutsideScheduleWindowOnBattery() {
        for mode in [SleepPreventionMode.aroundSchedule, .always] {
            let f = SleepPreventionFixture(mode: mode, offset: -4 * 3600, onAC: false)
            let state = f.makeState()
            state.reconcileSchedule(reason: "startup")
            state.reevaluateSleepPrevention(trigger: "schedule_changed")

            XCTAssertEqual(state.nextEvent?.date, f.target, "\(mode)")
            XCTAssertEqual(f.assertion.transitions, [], "\(mode)")
        }
    }

    func testAlwaysFollowsPowerSourceOutsideScheduleWindow() {
        let f = SleepPreventionFixture(mode: .always, offset: -4 * 3600, onAC: true)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup") // 다음 예약 06:00, 현재 02:00
        XCTAssertEqual(state.nextEvent?.date, f.target)

        f.power.isOnAC = false
        state.reevaluateSleepPrevention(trigger: "power_source_changed")
        XCTAssertFalse(f.assertion.isHeld)

        f.power.isOnAC = true
        state.reevaluateSleepPrevention(trigger: "power_source_changed")
        XCTAssertTrue(f.assertion.isHeld)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release", "acquire"])
    }

    func testLeadTimeReevaluationAcquiresExactlyThirtyMinutesBefore() {
        let f = SleepPreventionFixture(mode: .aroundSchedule, offset: -31 * 60, onAC: false)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup")
        state.reevaluateSleepPrevention(trigger: "schedule_changed")
        XCTAssertFalse(f.assertion.isHeld)

        f.clock.set(f.target.addingTimeInterval(-30 * 60 - 1))
        state.reevaluateSleepPrevention(trigger: "lead_time")
        XCTAssertFalse(f.assertion.isHeld)

        f.clock.set(f.target.addingTimeInterval(-30 * 60))
        state.reevaluateSleepPrevention(trigger: "lead_time")
        XCTAssertTrue(f.assertion.isHeld)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
    }

    func testAcquireFailureIsRetriedOnNextTrigger() {
        let f = SleepPreventionFixture(mode: .always, offset: -4 * 3600, onAC: true)
        f.assertion.nextAcquireResult = kIOReturnError
        let state = f.makeState()
        XCTAssertEqual(f.assertion.transitions, ["acquire_failed"])
        XCTAssertFalse(f.assertion.isHeld)

        f.assertion.nextAcquireResult = kIOReturnSuccess
        state.reevaluateSleepPrevention(trigger: "power_source_changed")
        XCTAssertEqual(f.assertion.transitions, ["acquire_failed", "acquire"])
        XCTAssertTrue(f.assertion.isHeld)
    }

    func testBlockedStartupStillReevaluatesOnce() {
        let f = SleepPreventionFixture(mode: .always, onAC: true)
        // 차단 사유는 생성 전에 정해 두어야 init의 조기 return 경로를 탄다.
        f.block.reason = "구버전 실행 중"
        let state = f.makeState(startScheduler: true)

        XCTAssertNotNil(state.operationBlockReason)
        XCTAssertNil(state.nextEvent)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
        XCTAssertTrue(f.assertion.isHeld)
    }

    func testFailedAcquireIsNeverFollowedByRelease() {
        let f = SleepPreventionFixture(mode: .always, offset: -4 * 3600, onAC: true)
        f.assertion.nextAcquireResult = kIOReturnError
        let state = f.makeState()
        state.reevaluateSleepPrevention(trigger: "power_source_changed")

        // 쥘 조건이 사라져도, 쥔 적이 없으므로 해제를 부르지 않는다.
        f.power.isOnAC = false
        state.reevaluateSleepPrevention(trigger: "power_source_changed")
        XCTAssertEqual(f.assertion.transitions, ["acquire_failed", "acquire_failed"])
        XCTAssertFalse(f.assertion.isHeld)
    }

    // MARK: - 자동 재평가(didSet)

    /// 진행 중인 워밍·확인·로그인 Task가 끝날 때까지 기다린다.
    private func finish(_ state: AppState) async throws {
        for _ in 0..<200 {
            if !state.isWorking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("작업 종료 시간 초과")
    }

    private struct LeadTimeScenarioResult {
        let fixture: SleepPreventionFixture
        let state: AppState
        /// 해제되는 순간의 `isWorking`과 `nextEvent.date`.
        let workingAtRelease: Bool?
        let nextEventAtRelease: Date?
    }

    /// 05:29 시작 → 05:30 선행 재평가 → 06:00 비활성 확인·워밍·활성 확인 → 종료.
    private func runLeadTimeScenario(mode: SleepPreventionMode, onAC: Bool) async throws -> LeadTimeScenarioResult {
        let f = SleepPreventionFixture(mode: mode, offset: -31 * 60, onAC: onAC)
        let state = f.makeState()
        // startScheduler: false에서는 init이 일정을 계산하지 않으므로 명시 호출한다.
        state.reconcileSchedule(reason: "startup")
        XCTAssertEqual(state.nextEvent?.date, f.target)
        XCTAssertFalse(f.assertion.isHeld, "05:29에는 아직 쥐지 않는다")

        f.clock.set(f.target.addingTimeInterval(-30 * 60))
        state.reevaluateSleepPrevention(trigger: "lead_time")
        XCTAssertTrue(f.assertion.isHeld, "05:30부터 쥔다")

        var workingAtRelease: Bool?
        var nextEventAtRelease: Date?
        f.assertion.onTransition = { [weak state] name in
            guard name == "release" else { return }
            workingAtRelease = state?.isWorking
            nextEventAtRelease = state?.nextEvent?.date
        }

        f.clock.set(f.target)
        state.handle(f.event)
        XCTAssertTrue(state.isWorking)
        XCTAssertTrue(f.assertion.isHeld, "워밍·확인 중에는 유지한다")
        try await finish(state)
        f.assertion.onTransition = nil

        return LeadTimeScenarioResult(fixture: f, state: state,
                                      workingAtRelease: workingAtRelease, nextEventAtRelease: nextEventAtRelease)
    }

    /// 선행 시각에 쥐고, 확인이 끝나 다음 예약이 11:00으로 바뀌는 순간 놓는지 확인한다.
    private func assertAcquiredAtLeadTimeAndReleasedAfterConfirmation(
        _ result: LeadTimeScenarioResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.fixture.assertion.transitions, ["acquire", "release"], file: file, line: line)
        XCTAssertFalse(result.fixture.assertion.isHeld, file: file, line: line)
        XCTAssertEqual(result.state.status, .succeeded, file: file, line: line)
        XCTAssertEqual(result.state.nextEvent?.date, result.fixture.reset, file: file, line: line)
        // 해제 트리거는 schedule_changed다. isWorking이 꺼진 시점에는 nextEvent가 아직 지난 06:00이라 유지된다.
        XCTAssertEqual(result.workingAtRelease, false, file: file, line: line)
        XCTAssertEqual(result.nextEventAtRelease, result.fixture.reset, file: file, line: line)
    }

    func testAroundScheduleAcquiresAtLeadTimeAndReleasesAfterConfirmation() async throws {
        let result = try await runLeadTimeScenario(mode: .aroundSchedule, onAC: true)
        assertAcquiredAtLeadTimeAndReleasedAfterConfirmation(result)
    }

    func testAroundScheduleWorksOnBattery() async throws {
        let result = try await runLeadTimeScenario(mode: .aroundSchedule, onAC: false)
        assertAcquiredAtLeadTimeAndReleasedAfterConfirmation(result)
    }

    func testAlwaysOnBatteryMatchesAroundSchedule() async throws {
        let result = try await runLeadTimeScenario(mode: .always, onAC: false)
        assertAcquiredAtLeadTimeAndReleasedAfterConfirmation(result)
    }

    func testAroundScheduleStaysHeldThroughRetries() async throws {
        let f = SleepPreventionFixture(mode: .aroundSchedule, error: .quotaUnavailable, onAC: false)
        let state = f.makeState()
        state.handle(f.event) // 06:00 조회 실패 → 30초 뒤 재시도
        try await finish(state)
        XCTAssertTrue(f.assertion.isHeld)

        for _ in 0..<3 {
            let retry = try XCTUnwrap(state.nextEvent)
            f.clock.set(retry.date)
            state.handle(retry)
            try await finish(state)
            XCTAssertTrue(f.assertion.isHeld)
        }

        // 네 번째 실패부터는 5분 간격이다. 그동안 한 번도 놓지 않는다.
        XCTAssertEqual(state.cycle.firstFailure?.attempts, 4)
        XCTAssertEqual(state.nextEvent?.date, f.clock.now().addingTimeInterval(300))
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
    }

    func testAroundScheduleReleasesWhenRetriesAreExhausted() async throws {
        let f = SleepPreventionFixture(mode: .aroundSchedule, offset: -10 * 60, error: .oauthRefreshFailed, onAC: false)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup") // 05:50, 예약 구간 안
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        f.clock.set(f.target)
        state.handle(f.event) // 재시도할 수 없는 인증 오류
        try await finish(state)

        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.nextEvent?.dayKey, "2026-09-15")
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])
        XCTAssertFalse(f.assertion.isHeld)
    }

    func testAlwaysKeepsHoldingWhenACArrivesDuringScheduleWindow() async throws {
        let f = SleepPreventionFixture(mode: .always, offset: -31 * 60, onAC: false)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup")
        f.clock.set(f.target.addingTimeInterval(-30 * 60))
        state.reevaluateSleepPrevention(trigger: "lead_time")
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        f.power.isOnAC = true
        state.reevaluateSleepPrevention(trigger: "power_source_changed")
        f.clock.set(f.target)
        state.handle(f.event)
        try await finish(state)

        // 예약 구간이 끝나도 전원이 연결돼 있으므로 계속 쥔다. 전이는 처음 한 번뿐이다.
        XCTAssertEqual(state.nextEvent?.date, f.reset)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
        XCTAssertTrue(f.assertion.isHeld)
    }

    func testBlockedOperationsFollowPlainRule() {
        for mode in SleepPreventionMode.allCases {
            for onAC in [true, false] {
                let label = "\(mode) onAC=\(onAC)"
                let f = SleepPreventionFixture(mode: mode, offset: -10 * 60, onAC: onAC)
                let state = f.makeState()
                state.reconcileSchedule(reason: "startup") // 05:50, 다음 예약 06:00
                XCTAssertEqual(f.assertion.isHeld, mode != .off, label)

                f.block.reason = "구버전 실행 중"
                XCTAssertFalse(state.refreshExecutionPermission(), label)

                // 차단 입력은 따로 없다. nextEvent가 nil이 된 결과만 규칙에 반영된다.
                XCTAssertNotNil(state.operationBlockReason, label)
                XCTAssertNil(state.nextEvent, label)
                XCTAssertEqual(f.assertion.isHeld, mode == .always && onAC, label)
            }
        }
    }

    func testCorruptSettingsBehaveAsOff() {
        let f = SleepPreventionFixture(mode: .always, offset: -10 * 60, onAC: true)
        f.defaults.set(Data("{broken settings".utf8), forKey: SettingsStore.settingsKey)
        let corruptStore = SettingsStore(defaults: f.defaults)
        XCTAssertEqual(corruptStore.issue?.area, .settings)
        XCTAssertEqual(corruptStore.issue?.kind, .corrupt)

        let state = f.makeState(store: corruptStore)
        state.reconcileSchedule(reason: "startup")

        XCTAssertEqual(state.settings.sleepPrevention, .off)
        XCTAssertNotNil(state.operationBlockReason)
        XCTAssertEqual(f.assertion.transitions, [])
    }

    // MARK: - Review Focus

    func testWakeInsideLeadWindowAcquiresAndBackwardClockChangeReleases() {
        let f = SleepPreventionFixture(mode: .aroundSchedule, offset: -60 * 60, onAC: false)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup") // 05:00
        XCTAssertEqual(f.assertion.transitions, [])

        // 잠든 사이 선행 시각(05:30)이 지났다. 깨어난 직후의 일정 재계산만으로 쥔다.
        f.clock.set(f.target.addingTimeInterval(-15 * 60))
        state.reconcileSchedule(reason: "system_wake")
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        // 시계가 04:00으로 되돌아가면 다시 30분보다 멀어진다.
        f.clock.set(f.target.addingTimeInterval(-2 * 3600))
        state.reconcileSchedule(reason: "clock_changed")
        XCTAssertEqual(state.nextEvent?.date, f.target)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])
    }

    func testAlwaysDoesNotFlapWhenUnpluggedInsideScheduleWindow() async throws {
        let f = SleepPreventionFixture(mode: .always, offset: -20 * 60, onAC: true)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup") // 05:40, 다음 예약 06:00
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        f.power.isOnAC = false
        state.reevaluateSleepPrevention(trigger: "power_source_changed")
        XCTAssertEqual(f.assertion.transitions, ["acquire"], "예약 구간 안에서는 해제·재획득하지 않는다")

        f.clock.set(f.target)
        state.handle(f.event)
        try await finish(state)

        // 배터리에서 예약 구간이 끝나면 놓는다.
        XCTAssertEqual(state.nextEvent?.date, f.reset)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])
    }

    func testManualWarmupAndLoginFarFromScheduleHoldOnlyWhileWorking() async throws {
        let f = SleepPreventionFixture(mode: .aroundSchedule, offset: -4 * 3600, active: true, onAC: false)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup") // 02:00, 다음 예약 06:00
        XCTAssertEqual(f.assertion.transitions, [])

        state.manualWarmup()
        XCTAssertTrue(state.isWorking)
        XCTAssertTrue(f.assertion.isHeld)
        try await finish(state)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])

        state.connectClaude() // 가짜 로그인. 브라우저를 열지 않는다.
        XCTAssertTrue(state.isWorking)
        XCTAssertTrue(f.assertion.isHeld)
        try await finish(state)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release", "acquire", "release"])

        XCTAssertEqual(state.nextEvent?.date, f.target)
        let logins = await f.backend.logins
        XCTAssertEqual(logins, 1)
    }

    func testRetriesThatCrossMidnightReleaseUntilNextLeadTime() async throws {
        let f = SleepPreventionFixture(mode: .aroundSchedule, error: .quotaUnavailable, onAC: false)
        let state = f.makeState()
        state.handle(f.event) // 06:00 조회 실패 → 30초 뒤 재시도
        try await finish(state)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        // 재시도가 이어지다 날짜가 바뀌었다(다음 날 00:04). 전날 예약은 버리고 오늘 첫 예약을 기다린다.
        let nextDayFirst = f.target.addingTimeInterval(86_400)
        f.clock.set(f.target.addingTimeInterval(18 * 3600 + 4 * 60))
        state.handle(try XCTUnwrap(state.nextEvent))
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.nextEvent?.date, nextDayFirst)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])

        f.clock.set(nextDayFirst.addingTimeInterval(-30 * 60))
        state.reevaluateSleepPrevention(trigger: "lead_time")
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release", "acquire"])
    }

    // MARK: - 설정 저장(applySettings)

    /// `applySettings`는 현재 달력의 시·분만 읽는다. 시험 기기의 시간대와 무관하게 같은 "분"을 만든다.
    private func localTime(hour: Int) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    /// 다른 저장소 인스턴스로 다시 읽은 저장값.
    private func storedMode(_ f: SleepPreventionFixture) -> SleepPreventionMode {
        SettingsStore(defaults: f.defaults).loadSettings().sleepPrevention
    }

    func testSwitchingToOffReleasesImmediately() {
        let f = SleepPreventionFixture(mode: .always, offset: -4 * 3600, onAC: true)
        let state = f.makeState()
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        XCTAssertTrue(state.applySettings(firstWarmupDate: localTime(hour: 6), weekdays: [2, 3, 4, 5, 6],
                                          excludeKoreanHolidays: false, sleepPrevention: .off))

        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])
        XCTAssertEqual(state.settings.sleepPrevention, .off)
        XCTAssertEqual(storedMode(f), .off)
    }

    func testApplySettingsWithNilSleepPreventionKeepsCurrentValue() {
        let f = SleepPreventionFixture(mode: .always, offset: -4 * 3600, onAC: true)
        let state = f.makeState()

        // 기존 호출자들과 같은 형태: 잠자기 방지 인자를 주지 않는다.
        XCTAssertTrue(state.applySettings(firstWarmupDate: localTime(hour: 9), weekdays: [2, 3],
                                          excludeKoreanHolidays: true))

        XCTAssertEqual(state.settings.firstWarmupMinutes, 9 * 60)
        XCTAssertEqual(state.settings.sleepPrevention, .always)
        XCTAssertEqual(storedMode(f), .always)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
    }

    func testRepairingCorruptSettingsAppliesSavedMode() {
        let f = SleepPreventionFixture(mode: .off, offset: -4 * 3600, onAC: true)
        f.defaults.set(Data("{broken settings".utf8), forKey: SettingsStore.settingsKey)
        let state = f.makeState(store: SettingsStore(defaults: f.defaults))
        XCTAssertNotNil(state.operationBlockReason)
        XCTAssertEqual(f.assertion.transitions, [])

        // 복구 화면에서 초안을 저장한다. 저장한 값이 바로 적용된다.
        XCTAssertTrue(state.applySettings(firstWarmupDate: localTime(hour: 6), weekdays: [2, 3, 4, 5, 6],
                                          excludeKoreanHolidays: false, sleepPrevention: .always))

        XCTAssertNil(state.operationBlockReason)
        XCTAssertEqual(state.settings.sleepPrevention, .always)
        XCTAssertEqual(storedMode(f), .always)
        XCTAssertEqual(f.assertion.transitions, ["acquire"])
    }

    func testChangingOnlyFirstWarmupTimeFollowsNewSchedule() {
        let f = SleepPreventionFixture(mode: .aroundSchedule, offset: -20 * 60, onAC: false)
        let state = f.makeState()
        state.reconcileSchedule(reason: "startup") // 05:40, 다음 예약 06:00
        XCTAssertEqual(f.assertion.transitions, ["acquire"])

        // 모드는 그대로 두고 첫 워밍만 09:00으로 옮긴다.
        XCTAssertTrue(state.applySettings(firstWarmupDate: localTime(hour: 9), weekdays: [2, 3, 4, 5, 6],
                                          excludeKoreanHolidays: false))
        XCTAssertEqual(state.nextEvent?.date, f.target.addingTimeInterval(3 * 3600))
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release"])

        // 다시 06:00으로 당기면 이미 30분 이내이므로 저장 즉시 쥔다.
        XCTAssertTrue(state.applySettings(firstWarmupDate: localTime(hour: 6), weekdays: [2, 3, 4, 5, 6],
                                          excludeKoreanHolidays: false))
        XCTAssertEqual(state.nextEvent?.date, f.target)
        XCTAssertEqual(state.settings.sleepPrevention, .aroundSchedule)
        XCTAssertEqual(f.assertion.transitions, ["acquire", "release", "acquire"])
    }

    func testInvariantHoldsAfterEveryPublicMutation() async throws {
        let f = SleepPreventionFixture(mode: .aroundSchedule, offset: -60 * 60, onAC: true)
        let state = f.makeState()
        var step = 0
        /// 매 단계 뒤: 보유 여부가 현재 입력의 판정과 같고, 저장소가 차단되지 않았다.
        func check(_ name: String) {
            step += 1
            let input = SleepPreventionPolicy.Input(
                mode: state.settings.sleepPrevention, now: f.clock.now(), nextEventDate: state.nextEvent?.date,
                isWorking: state.isWorking, isOnACPower: f.power.isOnAC)
            XCTAssertEqual(f.assertion.isHeld, SleepPreventionPolicy.shouldHold(input), "\(step). \(name)")
            XCTAssertNil(state.operationBlockReason, "\(step). \(name)")
        }
        func apply(_ mode: SleepPreventionMode) {
            XCTAssertTrue(state.applySettings(firstWarmupDate: localTime(hour: 6), weekdays: [2, 3, 4, 5, 6],
                                              excludeKoreanHolidays: false, sleepPrevention: mode), "\(mode)")
            check("applySettings \(mode)")
        }
        func setPower(onAC: Bool) {
            f.power.isOnAC = onAC
            state.reevaluateSleepPrevention(trigger: "power_source_changed")
            check("전원 onAC=\(onAC)")
        }

        check("init") // 05:00
        state.reconcileSchedule(reason: "startup")
        check("reconcile startup")

        for mode in [SleepPreventionMode.always, .off, .aroundSchedule] { apply(mode) }
        setPower(onAC: false)
        setPower(onAC: true)

        for reason in ["system_wake", "clock_changed", "screen_unlocked", "login_completed", "credential_available"] {
            state.reconcileSchedule(reason: reason)
            check("reconcile \(reason)")
        }

        f.clock.set(f.target.addingTimeInterval(-30 * 60)) // 05:30
        state.reevaluateSleepPrevention(trigger: "lead_time")
        check("lead_time")

        // handleTargetFailure는 대상 시각 이후에만 부른다. 그 전이면 저장 검증이 실패해 차단된다.
        f.clock.set(f.target) // 06:00
        XCTAssertTrue(state.markScheduledWindowStarted(f.event))
        check("markScheduledWindowStarted")
        state.handleTargetFailure(ClaudeServiceError.quotaUnavailable, event: f.event)
        check("handleTargetFailure")

        let retry = try XCTUnwrap(state.nextEvent)
        f.clock.set(retry.date) // 06:00:30
        state.handle(retry)
        check("handle 시작")
        try await finish(state)
        check("handle 완료")
        XCTAssertEqual(state.cycle.handledWindows, 1)
        XCTAssertEqual(state.nextEvent?.date, f.reset)

        state.manualWarmup()
        check("manualWarmup 시작")
        try await finish(state)
        check("manualWarmup 완료")

        apply(.always)
        setPower(onAC: false)
        apply(.off)
        XCTAssertGreaterThanOrEqual(step, 20)
    }
}
