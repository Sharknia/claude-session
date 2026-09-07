import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class AppStateTests: XCTestCase {
    @MainActor
    func testQuotaCacheExpiresAfterFiveMinutes() {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = QuotaCache(
            quota: QuotaWindow(active: true, usedPercent: 12, resetsAt: nil),
            fetchedAt: fetchedAt
        )

        XCTAssertTrue(AppState.isQuotaCacheFresh(cache, at: fetchedAt.addingTimeInterval(299)))
        XCTAssertFalse(AppState.isQuotaCacheFresh(cache, at: fetchedAt.addingTimeInterval(300)))
        XCTAssertFalse(AppState.isQuotaCacheFresh(cache, at: fetchedAt.addingTimeInterval(-1)))
    }

    func testCurrentFiveHourRangeUsesFixedTwentyFourHourFormat() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let resetsAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 19,
            minute: 20
        )))

        XCTAssertEqual(
            MenuDateFormatting.currentFiveHourRange(endingAt: resetsAt, calendar: calendar),
            "14:20–19:20"
        )
    }

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

    @MainActor
    func testAuthenticationFailureAdvancesOnceAndNeverReopensFirstWindow() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            let target = date(2026, 9, 7, 6, calendar: calendar)
            let settings = ScheduleSettings(firstWarmupMinutes: 360, weekdays: Set(1...7), excludeKoreanHolidays: false)
            store.saveSettings(settings)
            store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: target)))
            let state = AppState(store: store, engine: engine, startScheduler: false)
            let event = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
            state.markScheduledWindowStarted(event)
            state.handleTargetFailure(ClaudeServiceError.oauthRefreshFailed, event: event, at: target)
            let terminal = state.cycle
            XCTAssertEqual(terminal.handledWindows, 1)
            XCTAssertEqual(terminal.lastRecord?.status, .failed)
            XCTAssertEqual(state.nextEvent?.windowNumber, 2)
            XCTAssertEqual(state.nextEvent?.targetAt, target.addingTimeInterval(5 * 3600))

            // 실제 장애의 258회 재선택·missed 덮어쓰기를 재현하는 입력이다.
            for index in 0..<258 {
                state.advanceAfterUnresolvedWindow(targetAt: target, windowNumber: 1, status: .missed, message: "overwrite")
                state.handleTargetFailure(ClaudeServiceError.quotaUnavailable, event: event, at: target.addingTimeInterval(150))
                let next = engine.nextEvent(after: target.addingTimeInterval(Double(index) / 10), settings: settings, cycle: state.cycle)
                XCTAssertEqual(next?.windowNumber, 2)
            }
            XCTAssertEqual(state.cycle, terminal)
            XCTAssertEqual(store.loadDailyCycle(), terminal)
        }
    }

    @MainActor
    func testTransientRetriesPreserveFirstFailureThroughRestartAndGraceExpiry() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            let target = date(2026, 9, 7, 6, calendar: calendar)
            store.saveSettings(ScheduleSettings(firstWarmupMinutes: 360, weekdays: Set(1...7), excludeKoreanHolidays: false))
            store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: target)))
            let state = AppState(store: store, engine: engine, startScheduler: false)
            let event = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
            state.markScheduledWindowStarted(event)
            state.handleTargetFailure(ClaudeServiceError.oauthRefreshUnavailable, event: event, at: target)
            let original = state.cycle.firstFailure
            XCTAssertEqual(state.cycle.handledWindows, 0)
            XCTAssertEqual(state.nextEvent?.date, target.addingTimeInterval(30))
            state.markScheduledWindowStarted(event)
            state.handleTargetFailure(ClaudeServiceError.quotaRateLimited, event: event, at: target.addingTimeInterval(30))
            XCTAssertEqual(state.cycle.firstFailure, original)
            XCTAssertEqual(state.cycle.lastRecord?.message, original?.message)

            let restarted = AppState(store: store, engine: engine, startScheduler: false)
            restarted.reconcileMissedWindows(at: target.addingTimeInterval(181))
            XCTAssertEqual(restarted.cycle.handledWindows, 1)
            XCTAssertEqual(restarted.cycle.lastRecord?.status, .failed)
            XCTAssertEqual(restarted.cycle.lastRecord?.message, original?.message)
            let terminal = restarted.cycle
            restarted.reconcileMissedWindows(at: target.addingTimeInterval(182))
            XCTAssertEqual(restarted.cycle, terminal)
            XCTAssertEqual(terminal.nextResetAt, target.addingTimeInterval(5 * 3600))
        }
    }

    @MainActor
    func testTransientFailureAtRetryDeadlineClosesAsFailed() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            let target = date(2026, 9, 7, 6, calendar: calendar)
            store.saveSettings(ScheduleSettings(firstWarmupMinutes: 360, weekdays: Set(1...7), excludeKoreanHolidays: false))
            store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: target)))
            let state = AppState(store: store, engine: engine, startScheduler: false)
            let event = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
            state.markScheduledWindowStarted(event)
            state.handleTargetFailure(ClaudeServiceError.quotaUnavailable, event: event, at: target.addingTimeInterval(151))
            XCTAssertEqual(state.cycle.handledWindows, 1)
            XCTAssertEqual(state.cycle.lastRecord?.status, .failed)
            XCTAssertEqual(state.nextEvent?.windowNumber, 2)
        }
    }

    @MainActor
    func testRetryPolicySeparatesAuthenticationFromTransientFailures() {
        for error in [ClaudeServiceError.oauthRefreshFailed, .quotaUnauthorized, .managedCredentialsUnavailable, .credentialsUnavailable, .cliNotFound] {
            XCTAssertFalse(AppState.shouldRetryScheduledFailure(error))
        }
        for error in [ClaudeServiceError.oauthRefreshUnavailable, .quotaUnavailable, .quotaRateLimited] {
            XCTAssertTrue(AppState.shouldRetryScheduledFailure(error))
        }
        XCTAssertTrue(AppState.shouldRetryScheduledFailure(URLError(.timedOut)))
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
