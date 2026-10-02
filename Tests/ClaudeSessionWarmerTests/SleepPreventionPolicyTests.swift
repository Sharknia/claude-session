import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class SleepPreventionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lead = SleepPreventionPolicy.leadTime

    private func input(
        _ mode: SleepPreventionMode, next: Date?, working: Bool = false, onAC: Bool = false
    ) -> SleepPreventionPolicy.Input {
        SleepPreventionPolicy.Input(mode: mode, now: now, nextEventDate: next, isWorking: working, isOnACPower: onAC)
    }

    /// 스펙 3.2 표의 `nextEvent.date` 유형. (설명, 날짜, "30분 이내" 여부)
    private var dateCases: [(name: String, date: Date?, withinLeadTime: Bool)] {
        [
            ("예약 없음", nil, false),
            ("지난 예약", now.addingTimeInterval(-3600), true),
            ("미처리 예약이 현재 시각으로 당겨짐", now, true),
            ("재시도 30초 뒤", now.addingTimeInterval(30), true),
            ("재시도 5분 뒤", now.addingTimeInterval(300), true),
            ("정확히 30분 뒤(경계)", now.addingTimeInterval(lead), true),
            ("30분 1초 뒤", now.addingTimeInterval(lead + 1), false),
            ("5시간 뒤 후속 창", now.addingTimeInterval(18_000), false),
            ("다음 실행일 첫 예약", now.addingTimeInterval(86_400), false)
        ]
    }

    func testLeadTimeIsThirtyMinutes() {
        XCTAssertEqual(SleepPreventionPolicy.leadTime, 30 * 60)
    }

    func testOffNeverHolds() {
        for working in [false, true] {
            for onAC in [false, true] {
                for item in dateCases {
                    let value = input(.off, next: item.date, working: working, onAC: onAC)
                    XCTAssertFalse(SleepPreventionPolicy.shouldHold(value), item.name)
                    XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(value), item.name)
                }
            }
        }
    }

    func testAroundScheduleHoldsWithinLeadTimeOrWhileWorking() {
        for item in dateCases {
            XCTAssertEqual(SleepPreventionPolicy.shouldHold(input(.aroundSchedule, next: item.date)),
                           item.withinLeadTime, item.name)
            // 진행 중이면 다음 예약과 무관하게 쥔다.
            XCTAssertTrue(SleepPreventionPolicy.shouldHold(input(.aroundSchedule, next: item.date, working: true)),
                          item.name)
        }
    }

    func testAroundScheduleIgnoresPowerSource() {
        for working in [false, true] {
            for item in dateCases {
                let onBattery = SleepPreventionPolicy.shouldHold(
                    input(.aroundSchedule, next: item.date, working: working, onAC: false))
                let onAC = SleepPreventionPolicy.shouldHold(
                    input(.aroundSchedule, next: item.date, working: working, onAC: true))
                XCTAssertEqual(onBattery, onAC, item.name)
            }
        }
    }

    func testAlwaysHoldsOnACOrWithinScheduleWindow() {
        for working in [false, true] {
            for item in dateCases {
                XCTAssertTrue(SleepPreventionPolicy.shouldHold(
                    input(.always, next: item.date, working: working, onAC: true)), item.name)
                // 배터리에서는 같은 입력의 `예약 전후만`과 같다.
                XCTAssertEqual(
                    SleepPreventionPolicy.shouldHold(input(.always, next: item.date, working: working, onAC: false)),
                    SleepPreventionPolicy.shouldHold(input(.aroundSchedule, next: item.date, working: working, onAC: false)),
                    item.name)
            }
        }
    }

    func testAlwaysOnACHoldsWithoutAnySchedule() {
        // 다음 예약이 없거나 차단 상태여도 예외를 두지 않는다(스펙 3.5).
        XCTAssertTrue(SleepPreventionPolicy.shouldHold(input(.always, next: nil, working: false, onAC: true)))
    }

    func testNextEvaluationDateOnlyWhenNotHoldingWithPendingSchedule() {
        let far = now.addingTimeInterval(18_000)
        let expected = far.addingTimeInterval(-lead)

        XCTAssertEqual(SleepPreventionPolicy.nextEvaluationDate(input(.aroundSchedule, next: far)), expected)
        XCTAssertEqual(SleepPreventionPolicy.nextEvaluationDate(input(.always, next: far, onAC: false)), expected)
        XCTAssertGreaterThan(expected, now)

        XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(input(.always, next: far, onAC: true)))
        XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(input(.aroundSchedule, next: far, working: true)))
        XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(input(.aroundSchedule, next: now.addingTimeInterval(lead))))
        XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(input(.aroundSchedule, next: nil)))
        XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(input(.always, next: nil, onAC: false)))
        XCTAssertNil(SleepPreventionPolicy.nextEvaluationDate(input(.off, next: far)))
    }
}

/// 실제 IOKit을 호출하지 않는 경계 테스트. 전원 종류 분류와 어서션 이름만 고정한다.
final class PowerSourceTests: XCTestCase {
    func testOnlyACPowerCountsAsAC() {
        XCTAssertTrue(PowerSource.isACPower(providingPowerSourceType: "AC Power"))
        XCTAssertFalse(PowerSource.isACPower(providingPowerSourceType: "Battery Power"))
        XCTAssertFalse(PowerSource.isACPower(providingPowerSourceType: "UPS Power"))
        // 조회 실패는 보수적으로 배터리와 같이 취급한다.
        XCTAssertFalse(PowerSource.isACPower(providingPowerSourceType: nil))
        XCTAssertFalse(PowerSource.isACPower(providingPowerSourceType: ""))
    }

    @MainActor
    func testAssertionNameIsOneShortASCIIConstant() {
        XCTAssertEqual(IdleSleepAssertion.name, "ClaudeSessionWarmer sleep prevention")
        XCTAssertTrue(IdleSleepAssertion.name.allSatisfy(\.isASCII))
        XCTAssertLessThanOrEqual(IdleSleepAssertion.name.count, 128)
    }
}
