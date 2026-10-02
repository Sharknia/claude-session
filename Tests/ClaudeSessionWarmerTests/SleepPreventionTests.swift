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
    func makeState(store storeOverride: SettingsStore? = nil) -> AppState {
        let clock = clock, backend = backend, power = power, block = block
        return AppState(
            store: storeOverride ?? store,
            engine: engine,
            startScheduler: false,
            executionCheck: { block.reason },
            clock: { clock.now() },
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
}
