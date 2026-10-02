import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import notify

/// 입력만으로 "지금 유휴 잠자기 방지 어서션을 쥐어야 하는가"를 결정한다. I/O와 상태를 갖지 않는다.
enum SleepPreventionPolicy {
    /// 다음 예약 몇 초 전부터 쥐는가. 30분.
    static let leadTime: TimeInterval = 30 * 60

    struct Input: Equatable, Sendable {
        var mode: SleepPreventionMode
        var now: Date
        /// 타이머가 실제로 발화하는 시각(`ScheduledEvent.date`). 재시도 시각이 여기에 들어온다.
        var nextEventDate: Date?
        var isWorking: Bool
        var isOnACPower: Bool
    }

    static func shouldHold(_ input: Input) -> Bool {
        switch input.mode {
        case .off: return false
        case .aroundSchedule: return isWithinScheduleWindow(input)
        // `상시`는 `예약 전후만`의 상위 집합이다. 전원 연결 중에는 예외 없이 쥔다.
        case .always: return input.isOnACPower || isWithinScheduleWindow(input)
        }
    }

    /// 워밍·활성화 확인이 진행 중이거나 다음 예약 30분 전 이후인가.
    static func isWithinScheduleWindow(_ input: Input) -> Bool {
        if input.isWorking { return true }
        guard let next = input.nextEventDate else { return false }
        return next.addingTimeInterval(-leadTime) <= input.now
    }

    /// `끔`이 아니고 지금은 쥘 조건이 아니며 다음 예약이 있으면 `nextEventDate - leadTime`. 그 외 nil.
    /// `상시`도 배터리에서는 이 시각에 선행 타이머가 필요하다.
    static func nextEvaluationDate(_ input: Input) -> Date? {
        guard input.mode != .off, !shouldHold(input), let next = input.nextEventDate else { return nil }
        return next.addingTimeInterval(-leadTime)
    }
}

/// 테스트에서 가짜로 바꾸는 경계. MainActor에서만 쓴다.
@MainActor
protocol IdleSleepAssertionHolding: AnyObject {
    var isHeld: Bool { get }
    /// 이미 쥐고 있으면 `kIOReturnSuccess`. 실패하면 IOKit 반환값을 그대로 돌려주고 `isHeld`는 false를 유지한다.
    func acquire() -> IOReturn
    /// 쥐고 있지 않으면 `kIOReturnSuccess`. 해제 결과와 무관하게 `isHeld`는 false가 된다.
    @discardableResult
    func release() -> IOReturn
}

/// `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep)` 하나만 감싼다.
/// 유휴로 인한 시스템 잠자기만 막는다. 디스플레이 꺼짐과 유휴 외 원인의 잠자기는 막지 않는다.
@MainActor
final class IdleSleepAssertion: IdleSleepAssertionHolding {
    /// `pmset -g assertions`에 보이는 이름. 모드가 바뀌어도 같은 이름을 쓴다.
    static let name = "ClaudeSessionWarmer sleep prevention"

    private var assertionID: IOPMAssertionID?

    var isHeld: Bool { assertionID != nil }

    func acquire() -> IOReturn {
        if assertionID != nil { return kIOReturnSuccess }
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.name as CFString,
            &newID
        )
        if result == kIOReturnSuccess { assertionID = newID }
        return result
    }

    @discardableResult
    func release() -> IOReturn {
        guard let currentID = assertionID else { return kIOReturnSuccess }
        // 해제가 실패해도 다시 시도하지 않는다. 프로세스가 끝나면 OS가 정리한다.
        assertionID = nil
        return IOPMAssertionRelease(currentID)
    }

    // deinit은 nonisolated라 MainActor 메서드 release()를 부를 수 없다. 저장 프로퍼티만 직접 읽어 해제한다.
    deinit {
        if let currentID = assertionID { _ = IOPMAssertionRelease(currentID) }
    }
}

enum PowerSource {
    /// 지금 전원 어댑터(무제한 전원)로 동작 중인가. 배터리·UPS·조회 실패는 false.
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let providingType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        return isACPower(providingPowerSourceType: providingType.map { $0 as String })
    }

    /// `IOPSGetProvidingPowerSourceType`의 반환 문자열을 분류한다. "AC Power"일 때만 true.
    static func isACPower(providingPowerSourceType: String?) -> Bool {
        providingPowerSourceType == kIOPMACPowerKey
    }
}

/// `kIOPSNotifyPowerSource`를 notify(3)로 구독한다. 전원 공급원이 바뀔 때만 오고 잔량 변화에는 오지 않는다.
/// 등록 실패는 로그만 남긴다. 전원 상태는 재평가마다 다시 읽으므로 기능은 계속 동작한다.
final class PowerSourceObserver {
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    /// `onChange`는 메인 큐에서 불린다.
    init(onChange: @escaping @Sendable () -> Void) {
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { _ in onChange() }
        if status != NOTIFY_STATUS_OK {
            token = NOTIFY_TOKEN_INVALID
            diagnosticLog("power.observer_failed", ["status": "\(status)"])
        }
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }
}
