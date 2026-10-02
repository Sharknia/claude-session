import Foundation

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
