import Foundation
import XCTest
import Security
@testable import ClaudeSessionWarmer

final class AppStateTests: XCTestCase {
    @MainActor
    func testExistingSatisfiedRecordUsesUpdatedDisplayWithoutChangingHistory() {
        withStore { store in
            let record = WarmupRecord(timestamp: Date(), status: .satisfied, message: "이미 열린 창을 확인했습니다.")
            store.saveDailyCycle(DailyCycle(lastRecord: record))
            let state = AppState(store: store, startScheduler: false)
            XCTAssertEqual(state.statusMessage, "이미 세션이 활성화되었습니다.")
            XCTAssertEqual(state.cycle.lastRecord?.displayMessage, state.statusMessage)
            XCTAssertEqual(store.loadDailyCycle().lastRecord, record)
        }
    }

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
    func testUnconfirmedTransmissionNeverExpiresByTimeAlone() {
        withStore { store in
            let target = Date(timeIntervalSince1970: 1_800_000_000)
            store.saveDailyCycle(DailyCycle(lastWarmupTargetAt: target))
            let state = AppState(store: store, startScheduler: false)
            for delay in [0.0, 181, 600, 86_400] {
                XCTAssertTrue(state.shouldSuppressWarmup(for: target.addingTimeInterval(delay),
                                                        at: target.addingTimeInterval(delay)))
            }
        }
    }

    @MainActor
    func testFailuresRemainPendingAndRetriesAreBoundedAcrossRestart() {
        withStore { store in
            let calendar = seoulCalendar()
            let engine = ScheduleEngine(calendar: calendar)
            let target = date(2026, 9, 7, 6, calendar: calendar)
            store.saveSettings(ScheduleSettings(firstWarmupMinutes: 360, weekdays: Set(1...7), excludeKoreanHolidays: false))
            let event = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
            var original: String?
            for attempt in 1...4 {
                let now = target.addingTimeInterval(10_800 + Double(attempt * 30))
                let state = AppState(store: store, engine: engine, startScheduler: false, clock: { now })
                state.markScheduledWindowStarted(event)
                state.handleTargetFailure(ClaudeServiceError.quotaUnavailable, event: event, at: now)
                original = original ?? state.cycle.firstFailure?.message
                XCTAssertEqual(state.cycle.handledWindows, 0)
                XCTAssertEqual(state.cycle.nextResetAt, target)
                XCTAssertEqual(state.cycle.firstFailure?.attempts, attempt)
                XCTAssertEqual(state.cycle.firstFailure?.message, original)
                if attempt <= 3 {
                    XCTAssertEqual(state.nextEvent?.date, now.addingTimeInterval(30))
                    XCTAssertEqual(state.nextEvent?.windowNumber, 1)
                } else {
                    XCTAssertEqual(state.status, .failed)
                    XCTAssertNil(state.cycle.firstFailure?.retryAt)
                    XCTAssertEqual(state.nextEvent?.dayKey, "2026-09-08")
                }
            }
            let restarted = AppState(store: store, engine: engine, startScheduler: false, clock: { target.addingTimeInterval(14_000) })
            restarted.reconcileSchedule(reason: "clock_changed")
            XCTAssertEqual(restarted.nextEvent?.dayKey, "2026-09-08")
            XCTAssertEqual(restarted.cycle.firstFailure?.attempts, 4)
            restarted.reconcileSchedule(reason: "system_wake")
            XCTAssertEqual(restarted.nextEvent?.dayKey, "2026-09-07")
            XCTAssertEqual(restarted.nextEvent?.targetAt, target)
            XCTAssertEqual(restarted.cycle.firstFailure?.attempts, 4)
        }
    }

    @MainActor
    func testAuthenticationFailureWaitsWithoutConsumingWindow() {
        withStore { store in
            let engine = ScheduleEngine(calendar: seoulCalendar())
            let target = date(2026, 9, 7, 6, calendar: seoulCalendar())
            let state = AppState(store: store, engine: engine, startScheduler: false, clock: { target })
            let event = ScheduledEvent(date: target, targetAt: target, dayKey: engine.dayKey(for: target), windowNumber: 1)
            state.markScheduledWindowStarted(event)
            state.handleTargetFailure(ClaudeServiceError.oauthRefreshFailed, event: event)
            XCTAssertEqual(state.cycle.handledWindows, 0)
            XCTAssertEqual(state.cycle.nextResetAt, target)
            XCTAssertNil(state.cycle.firstFailure?.retryAt)
            XCTAssertEqual(state.status, .failed)
            XCTAssertEqual(state.nextEvent?.dayKey, "2026-09-08")
        }
    }

    @MainActor
    func testRetryPolicySeparatesAuthenticationFromTransientFailures() {
        for error in [ClaudeServiceError.oauthRefreshFailed, .quotaUnauthorized, .managedCredentialsUnavailable,
                      .credentialsUnavailable(errSecMissingEntitlement), .credentialsUnavailable(errSecDecode), .cliNotFound] {
            XCTAssertFalse(AppState.shouldRetryScheduledFailure(error))
        }
        for error in [ClaudeServiceError.oauthRefreshUnavailable, .quotaUnavailable, .quotaRateLimited] {
            XCTAssertTrue(AppState.shouldRetryScheduledFailure(error))
        }
        XCTAssertTrue(AppState.shouldRetryScheduledFailure(URLError(.timedOut)))
        for status in [errSecAuthFailed, errSecNotAvailable, errSecInteractionNotAllowed, errSecInDarkWake] {
            XCTAssertTrue(AppState.shouldRetryScheduledFailure(ClaudeServiceError.credentialsUnavailable(status)))
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
