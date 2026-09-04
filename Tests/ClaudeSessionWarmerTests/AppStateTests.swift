import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class AppStateTests: XCTestCase {
    @MainActor
    func testBatchSettingsArePersistedAndReloaded() {
        withStore { store in
            let state = AppState(store: store, startScheduler: false)
            let date = Calendar.autoupdatingCurrent.date(
                bySettingHour: 8,
                minute: 20,
                second: 0,
                of: Date()
            )!

            XCTAssertTrue(state.applySettings(
                firstWarmupDate: date,
                weekdays: [1, 3, 7],
                excludeKoreanHolidays: false,
                launchAtLogin: false
            ))

            let saved = store.loadSettings()
            XCTAssertEqual(saved.firstWarmupMinutes, 8 * 60 + 20)
            XCTAssertEqual(saved.weekdays, [1, 3, 7])
            XCTAssertFalse(saved.excludeKoreanHolidays)

            let reloaded = AppState(store: store, startScheduler: false)
            XCTAssertEqual(reloaded.settings, saved)
        }
    }

    @MainActor
    func testBatchSettingsRejectEmptyWeekdaysWithoutSaving() {
        withStore { store in
            let state = AppState(store: store, startScheduler: false)
            let original = store.loadSettings()

            XCTAssertFalse(state.applySettings(
                firstWarmupDate: Date(),
                weekdays: [],
                excludeKoreanHolidays: false,
                launchAtLogin: false
            ))

            XCTAssertEqual(store.loadSettings(), original)
            XCTAssertEqual(state.settings, original)
        }
    }

    @MainActor
    func testPauseTodayPersistsAndEndsCurrentChain() {
        withStore { store in
            store.saveDailyCycle(DailyCycle(
                dayKey: "previous",
                handledWindows: 1,
                nextResetAt: Date().addingTimeInterval(3_600)
            ))
            let state = AppState(store: store, startScheduler: false)

            state.pauseToday()

            let saved = store.loadDailyCycle()
            XCTAssertTrue(saved.pausedToday)
            XCTAssertNil(saved.nextResetAt)
            XCTAssertEqual(saved.lastRecord?.status, .skipped)
        }
    }

    @MainActor
    func testSkipNextPersistsWithoutRemovingFollowUp() {
        withStore { store in
            let nextReset = Date().addingTimeInterval(3_600)
            store.saveDailyCycle(DailyCycle(
                dayKey: ScheduleEngine().dayKey(for: Date()),
                handledWindows: 1,
                nextResetAt: nextReset
            ))
            let state = AppState(store: store, startScheduler: false)

            state.skipNextWarmup()

            let saved = store.loadDailyCycle()
            XCTAssertTrue(saved.skipNext)
            XCTAssertEqual(saved.nextResetAt, nextReset)
            XCTAssertEqual(saved.lastRecord?.status, .skipped)
        }
    }

    @MainActor
    func testFirstAndSecondFailuresKeepSchedulingTheDailyChain() {
        withStore { store in
            let firstTarget = Date(timeIntervalSince1970: 1_800_000_000)
            let state = AppState(store: store, startScheduler: false)

            state.advanceAfterUnresolvedWindow(
                targetAt: firstTarget,
                windowNumber: 1,
                status: .failed,
                message: "first failed"
            )
            XCTAssertEqual(state.cycle.handledWindows, 1)
            XCTAssertEqual(
                state.cycle.nextResetAt,
                firstTarget.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            )

            let secondTarget = try! XCTUnwrap(state.cycle.nextResetAt)
            state.advanceAfterUnresolvedWindow(
                targetAt: secondTarget,
                windowNumber: 2,
                status: .failed,
                message: "second failed"
            )
            XCTAssertEqual(state.cycle.handledWindows, 2)
            XCTAssertEqual(
                state.cycle.nextResetAt,
                secondTarget.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            )
        }
    }

    @MainActor
    func testConsumedSkipContinuesToFollowingWindow() {
        withStore { store in
            let target = Date(timeIntervalSince1970: 1_800_000_000)
            store.saveDailyCycle(DailyCycle(
                dayKey: "2026-09-04",
                handledWindows: 1,
                nextResetAt: target,
                skipNext: true
            ))
            let state = AppState(store: store, startScheduler: false)

            state.advanceAfterUnresolvedWindow(
                targetAt: target,
                windowNumber: 2,
                status: .skipped,
                message: "다음 워밍 1회 건너뜀",
                consumingSkip: true
            )

            XCTAssertEqual(state.cycle.handledWindows, 2)
            XCTAssertFalse(state.cycle.skipNext)
            XCTAssertEqual(
                state.cycle.nextResetAt,
                target.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            )
        }
    }

    @MainActor
    func testThirdUnresolvedWindowEndsTheDailyChain() {
        withStore { store in
            let target = Date(timeIntervalSince1970: 1_800_000_000)
            store.saveDailyCycle(DailyCycle(
                dayKey: "2026-09-04",
                handledWindows: 2,
                nextResetAt: target
            ))
            let state = AppState(store: store, startScheduler: false)

            state.advanceAfterUnresolvedWindow(
                targetAt: target,
                windowNumber: 3,
                status: .failed,
                message: "third failed"
            )

            XCTAssertEqual(state.cycle.handledWindows, 3)
            XCTAssertNil(state.cycle.nextResetAt)
        }
    }

    @MainActor
    func testStartedWindowPersistsTargetForRestartRecovery() {
        withStore { store in
            let target = Date(timeIntervalSince1970: 1_800_000_000)
            let event = ScheduledEvent(
                date: target,
                targetAt: target,
                dayKey: "2027-01-15",
                windowNumber: 1
            )
            let state = AppState(store: store, startScheduler: false)

            state.markScheduledWindowStarted(event)

            XCTAssertEqual(store.loadDailyCycle().nextResetAt, target)
            XCTAssertEqual(store.loadDailyCycle().lastRecord?.status, .checking)
        }
    }

    @MainActor
    func testRestartTwoMinutesAfterFirstTargetMarksItMissedWithoutCalling() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            store.saveSettings(ScheduleSettings(
                firstWarmupMinutes: 6 * 60,
                weekdays: Set(1...7),
                excludeKoreanHolidays: false
            ))
            let state = AppState(store: store, engine: engine, startScheduler: false)
            let firstTarget = date(2026, 9, 4, 6, calendar: calendar)

            state.reconcileMissedWindows(at: firstTarget.addingTimeInterval(2 * 60))

            XCTAssertEqual(state.cycle.handledWindows, 1)
            XCTAssertEqual(state.cycle.lastRecord?.status, .missed)
            XCTAssertNil(state.cycle.lastWarmupTargetAt)
            XCTAssertEqual(
                state.cycle.nextResetAt,
                firstTarget.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            )
        }
    }

    @MainActor
    func testRestartAfterGraceAdvancesSecondAndThirdFallbacks() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            store.saveSettings(ScheduleSettings(
                firstWarmupMinutes: 60,
                weekdays: Set(1...7),
                excludeKoreanHolidays: false
            ))
            let state = AppState(store: store, engine: engine, startScheduler: false)
            let firstTarget = date(2026, 9, 4, 1, calendar: calendar)
            let secondTarget = firstTarget.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            let thirdTarget = secondTarget.addingTimeInterval(ScheduleEngine.quotaWindowDuration)

            state.reconcileMissedWindows(at: secondTarget.addingTimeInterval(4 * 60))
            XCTAssertEqual(state.cycle.handledWindows, 2)
            XCTAssertEqual(state.cycle.nextResetAt, thirdTarget)

            state.reconcileMissedWindows(at: thirdTarget.addingTimeInterval(4 * 60))
            XCTAssertEqual(state.cycle.handledWindows, 3)
            XCTAssertNil(state.cycle.nextResetAt)
        }
    }

    @MainActor
    func testRecentManualWarmupMarkerSuppressesDuplicateForThreeMinutes() {
        withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            store.saveDailyCycle(DailyCycle(
                lastWarmupTargetAt: now.addingTimeInterval(-2 * 60)
            ))
            let state = AppState(store: store, startScheduler: false)

            XCTAssertTrue(state.hasRecentWarmupAttempt(at: now))
            XCTAssertFalse(state.hasRecentWarmupAttempt(at: now.addingTimeInterval(61)))
        }
    }

    @MainActor
    func testRestartConsumesPendingFirstSkipOnlyAfterTarget() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            let firstTarget = date(2026, 9, 4, 6, calendar: calendar)
            let todayKey = engine.dayKey(for: firstTarget)
            store.saveSettings(ScheduleSettings(
                firstWarmupMinutes: 6 * 60,
                weekdays: Set(1...7),
                excludeKoreanHolidays: false
            ))
            store.saveDailyCycle(DailyCycle(dayKey: todayKey, skipNext: true))
            let state = AppState(store: store, engine: engine, startScheduler: false)

            state.reconcileMissedWindows(at: firstTarget.addingTimeInterval(-1))
            XCTAssertEqual(state.cycle.handledWindows, 0)
            XCTAssertTrue(state.cycle.skipNext)
            XCTAssertNil(state.cycle.nextResetAt)

            state.reconcileMissedWindows(at: firstTarget.addingTimeInterval(2 * 60))
            XCTAssertEqual(state.cycle.handledWindows, 1)
            XCTAssertFalse(state.cycle.skipNext)
            XCTAssertEqual(state.cycle.lastRecord?.status, .skipped)
            XCTAssertEqual(
                state.cycle.nextResetAt,
                firstTarget.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            )
        }
    }

    @MainActor
    func testScheduledWarmupSuppressesRecentManualMarker() {
        withStore { store in
            let target = Date(timeIntervalSince1970: 1_800_000_000)
            store.saveDailyCycle(DailyCycle(
                lastWarmupTargetAt: target.addingTimeInterval(-60)
            ))
            let state = AppState(store: store, startScheduler: false)

            XCTAssertTrue(state.shouldSuppressWarmup(for: target, at: target))
            XCTAssertTrue(
                state.shouldSuppressWarmup(
                    for: target,
                    at: target.addingTimeInterval(ScheduleEngine.windowTolerance)
                )
            )
            XCTAssertFalse(
                state.shouldSuppressWarmup(
                    for: target.addingTimeInterval(600),
                    at: target.addingTimeInterval(181)
                )
            )
        }
    }

    private func withStore(_ body: (SettingsStore) -> Void) {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(SettingsStore(defaults: defaults))
    }

    private func seoulCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
