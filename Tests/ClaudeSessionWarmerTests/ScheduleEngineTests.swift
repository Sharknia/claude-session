import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class ScheduleEngineTests: XCTestCase {
    private var calendar: Calendar!
    private var engine: ScheduleEngine!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        self.calendar = calendar
        self.engine = ScheduleEngine(calendar: calendar)
    }

    func testSelectedWeekdayIsEligible() {
        let settings = ScheduleSettings(weekdays: [2, 3, 4, 5, 6])

        XCTAssertTrue(engine.isExecutionDay(date(2026, 9, 4), settings: settings)) // Friday
        XCTAssertFalse(engine.isExecutionDay(date(2026, 9, 5), settings: settings)) // Saturday
    }

    func testOfficialAndSubstituteHolidaysAreExcluded() {
        let settings = ScheduleSettings(weekdays: Set(1...7))

        XCTAssertEqual(ScheduleEngine.supportedHolidayYears, 2026...2027)
        XCTAssertTrue(engine.isKoreanHoliday(date(2026, 5, 1))) // Labor Day
        XCTAssertTrue(engine.isKoreanHoliday(date(2026, 8, 17))) // substitute holiday
        XCTAssertTrue(engine.isKoreanHoliday(date(2027, 7, 19))) // Constitution Day substitute
        XCTAssertFalse(engine.isExecutionDay(date(2027, 7, 19), settings: settings))
        XCTAssertFalse(engine.isExecutionDay(date(2028, 1, 3), settings: settings))
        XCTAssertNil(engine.nextValidFirstWarmup(after: date(2027, 12, 31, 23), settings: settings))

        let holidayReset = DailyCycle(
            dayKey: "2026-08-14",
            handledWindows: 1,
            nextResetAt: date(2026, 8, 17, 11)
        )
        let next = engine.nextEvent(
            after: date(2026, 8, 17, 10),
            settings: settings,
            cycle: holidayReset
        )
        XCTAssertEqual(next?.targetAt, date(2026, 8, 18, 6))
    }

    func testHolidayExclusionCanBeDisabled() {
        let settings = ScheduleSettings(
            weekdays: Set(1...7),
            excludeKoreanHolidays: false
        )

        XCTAssertTrue(engine.isExecutionDay(date(2026, 10, 5), settings: settings))
    }

    func testNextFirstWarmupSkipsHolidayAndWeekend() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let thursdayEvening = date(2026, 4, 30, 18)

        let next = engine.nextValidFirstWarmup(after: thursdayEvening, settings: settings)

        XCTAssertEqual(next, date(2026, 5, 4, 6))
    }

    func testWarmupWindowUsesThreeMinuteDeadline() {
        let target = date(2026, 9, 4, 11)
        let timing = engine.timing(for: target)

        XCTAssertEqual(timing.expiresAt, date(2026, 9, 4, 11, 3))
        XCTAssertEqual(engine.position(of: target, at: date(2026, 9, 4, 11, 3)), .actionable)
        XCTAssertEqual(engine.position(of: target, at: date(2026, 9, 4, 11, 3, 1)), .missed)
    }

    func testFirstWindowSchedulesAtTargetTime() {
        let settings = ScheduleSettings(firstWarmupMinutes: 9 * 60, weekdays: [6])
        let cycle = DailyCycle()

        let wellBeforeTarget = engine.nextEvent(
            after: date(2026, 9, 4, 8, 50),
            settings: settings,
            cycle: cycle
        )
        let justBeforeTarget = engine.nextEvent(
            after: date(2026, 9, 4, 8, 58),
            settings: settings,
            cycle: cycle
        )

        XCTAssertEqual(wellBeforeTarget?.date, date(2026, 9, 4, 9))
        XCTAssertEqual(wellBeforeTarget?.windowNumber, 1)
        XCTAssertEqual(justBeforeTarget?.date, date(2026, 9, 4, 9))
    }

    func testFirstWindowRemainsActionableForThreeMinutes() {
        let settings = ScheduleSettings(firstWarmupMinutes: 9 * 60, weekdays: [6])

        let event = engine.nextEvent(
            after: date(2026, 9, 4, 9, 2),
            settings: settings,
            cycle: DailyCycle()
        )

        XCTAssertEqual(event?.targetAt, date(2026, 9, 4, 9))
        XCTAssertEqual(event?.date, date(2026, 9, 4, 9, 2))
        XCTAssertEqual(event?.windowNumber, 1)
    }

    func testActiveCycleUsesActualResetForSecondWindow() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let cycle = DailyCycle(
            dayKey: "2026-09-04",
            handledWindows: 1,
            nextResetAt: date(2026, 9, 4, 11)
        )

        let event = engine.nextEvent(
            after: date(2026, 9, 4, 10, 50),
            settings: settings,
            cycle: cycle
        )

        XCTAssertEqual(event?.targetAt, date(2026, 9, 4, 11))
        XCTAssertEqual(event?.date, date(2026, 9, 4, 11))
        XCTAssertEqual(event?.windowNumber, 2)
    }

    func testThreeHandledWindowsEndTodayAndScheduleNextExecutionDay() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let cycle = DailyCycle(
            dayKey: "2026-09-04",
            handledWindows: 3,
            nextResetAt: date(2026, 9, 4, 21)
        )

        let event = engine.nextEvent(
            after: date(2026, 9, 4, 16, 1),
            settings: settings,
            cycle: cycle
        )

        XCTAssertEqual(event?.targetAt, date(2026, 9, 7, 6))
        XCTAssertEqual(event?.windowNumber, 1)
    }

    func testSkipNextStillSchedulesPendingNextEvent() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let cycle = DailyCycle(
            dayKey: "2026-09-04",
            handledWindows: 1,
            nextResetAt: date(2026, 9, 4, 11),
            skipNext: true
        )

        let event = engine.nextEvent(
            after: date(2026, 9, 4, 10),
            settings: settings,
            cycle: cycle
        )

        XCTAssertEqual(event?.targetAt, date(2026, 9, 4, 11))
        XCTAssertEqual(event?.windowNumber, 2)
    }

    func testPauseTodayEndsRemainingDailyChain() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let pausedBeforeFirst = engine.nextEvent(
            after: date(2026, 9, 4, 5),
            settings: settings,
            cycle: DailyCycle(dayKey: "2026-09-04", pausedToday: true)
        )

        XCTAssertEqual(pausedBeforeFirst?.targetAt, date(2026, 9, 7, 6))
    }

    func testElapsedResetIsNotCaughtUp() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let cycle = DailyCycle(
            dayKey: "2026-09-04",
            handledWindows: 1,
            nextResetAt: date(2026, 9, 4, 11)
        )

        let withinTolerance = engine.nextEvent(
            after: date(2026, 9, 4, 11, 2),
            settings: settings,
            cycle: cycle
        )
        let missed = engine.nextEvent(
            after: date(2026, 9, 4, 11, 4),
            settings: settings,
            cycle: cycle
        )

        XCTAssertEqual(withinTolerance?.date, date(2026, 9, 4, 11, 2))
        XCTAssertEqual(withinTolerance?.windowNumber, 2)
        XCTAssertEqual(missed?.targetAt, date(2026, 9, 7, 6))
        XCTAssertEqual(missed?.windowNumber, 1)
    }

    func testPreviousDayCycleDoesNotContinueAfterMidnight() {
        let settings = ScheduleSettings(firstWarmupMinutes: 6 * 60)
        let cycle = DailyCycle(
            dayKey: "2026-09-04",
            handledWindows: 1,
            nextResetAt: date(2026, 9, 5, 2)
        )

        let event = engine.nextEvent(
            after: date(2026, 9, 5, 1, 50),
            settings: settings,
            cycle: cycle
        )

        XCTAssertEqual(event?.targetAt, date(2026, 9, 7, 6))
        XCTAssertEqual(event?.windowNumber, 1)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }
}
