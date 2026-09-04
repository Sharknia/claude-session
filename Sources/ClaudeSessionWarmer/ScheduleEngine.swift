import Foundation

struct ScheduledEvent: Equatable, Sendable {
    let date: Date
    let targetAt: Date
    let dayKey: String
    let windowNumber: Int
}

struct WarmupWindowTiming: Equatable, Sendable {
    let targetAt: Date
    let expiresAt: Date
}

enum WarmupWindowPosition: Equatable, Sendable {
    case scheduled
    case actionable
    case missed
}

/// Pure date calculations for the MVP scheduler.
///
/// This type deliberately does not own a timer or perform any I/O. Its caller asks
/// for one event, schedules it, updates `DailyCycle`, and asks again.
struct ScheduleEngine: Sendable {
    static let maximumWindowsPerDay = 3
    static let windowTolerance: TimeInterval = 3 * 60
    static let quotaWindowDuration: TimeInterval = 5 * 60 * 60
    static let supportedHolidayYears = 2026...2027

    private let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    func isExecutionDay(_ date: Date, settings: ScheduleSettings) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard settings.weekdays.contains(weekday) else { return false }

        guard settings.excludeKoreanHolidays else { return true }
        let year = calendar.component(.year, from: date)
        guard Self.supportedHolidayYears.contains(year) else { return false }
        return !Self.koreanHolidayDayKeys.contains(dayKey(for: date))
    }

    func isKoreanHoliday(_ date: Date) -> Bool {
        Self.koreanHolidayDayKeys.contains(dayKey(for: date))
    }

    func firstWarmup(on date: Date, settings: ScheduleSettings) -> Date? {
        guard isExecutionDay(date, settings: settings) else { return nil }

        let minutes = min(max(settings.firstWarmupMinutes, 0), 23 * 60 + 59)
        return calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: date))
    }

    /// Returns the first configured warmup strictly later than `date`.
    func nextValidFirstWarmup(after date: Date, settings: ScheduleSettings) -> Date? {
        guard !settings.weekdays.isEmpty else { return nil }

        var day = calendar.startOfDay(for: date)
        for _ in 0..<(366 * 3) {
            if let candidate = firstWarmup(on: day, settings: settings), candidate > date {
                return candidate
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = nextDay
        }
        return nil
    }

    func timing(for targetAt: Date) -> WarmupWindowTiming {
        WarmupWindowTiming(
            targetAt: targetAt,
            expiresAt: targetAt.addingTimeInterval(Self.windowTolerance)
        )
    }

    func position(of targetAt: Date, at now: Date) -> WarmupWindowPosition {
        let timing = timing(for: targetAt)
        if now < timing.targetAt { return .scheduled }
        if now <= timing.expiresAt { return .actionable }
        return .missed
    }

    /// Calculates only the next scheduler event. A returned date is never in the past.
    /// A reset whose +3 minute window has elapsed is abandoned rather than caught up.
    func nextEvent(
        after now: Date,
        settings: ScheduleSettings,
        cycle: DailyCycle
    ) -> ScheduledEvent? {
        let currentDayIsClosed = cycle.dayKey == dayKey(for: now)
            && (cycle.pausedToday || cycle.handledWindows >= Self.maximumWindowsPerDay)
        let freshFirst = currentDayIsClosed
            ? nextValidFirstWarmupAfterCurrentDay(now, settings: settings)
            : nextFirstWarmupOnOrAfter(now, settings: settings)

        if let resetEvent = nextResetEvent(after: now, settings: settings, cycle: cycle),
           freshFirst == nil || resetEvent.targetAt < freshFirst! {
            return resetEvent
        }

        guard let first = freshFirst else { return nil }
        return event(for: first, after: now, dayKey: dayKey(for: first), windowNumber: 1)
    }

    func newCycle(startingAt firstWarmup: Date) -> DailyCycle {
        DailyCycle(dayKey: dayKey(for: firstWarmup))
    }

    private func nextResetEvent(
        after now: Date,
        settings: ScheduleSettings,
        cycle: DailyCycle
    ) -> ScheduledEvent? {
        guard
            let originDayKey = cycle.dayKey,
            cycle.handledWindows > 0,
            cycle.handledWindows < Self.maximumWindowsPerDay,
            !cycle.pausedToday,
            let resetAt = cycle.nextResetAt,
            dayKey(for: resetAt) == originDayKey,
            isHolidaySchedulingAllowed(resetAt, settings: settings),
            position(of: resetAt, at: now) != .missed
        else {
            return nil
        }

        return event(
            for: resetAt,
            after: now,
            dayKey: originDayKey,
            windowNumber: cycle.handledWindows + 1
        )
    }

    private func nextFirstWarmupOnOrAfter(_ now: Date, settings: ScheduleSettings) -> Date? {
        guard !settings.weekdays.isEmpty else { return nil }

        let today = calendar.startOfDay(for: now)
        if let todayFirst = firstWarmup(on: today, settings: settings),
           position(of: todayFirst, at: now) != .missed {
            return todayFirst
        }
        return nextValidFirstWarmup(after: now, settings: settings)
    }

    private func isHolidaySchedulingAllowed(_ date: Date, settings: ScheduleSettings) -> Bool {
        guard settings.excludeKoreanHolidays else { return true }
        let year = calendar.component(.year, from: date)
        return Self.supportedHolidayYears.contains(year) && !isKoreanHoliday(date)
    }

    private func nextValidFirstWarmupAfterCurrentDay(
        _ now: Date,
        settings: ScheduleSettings
    ) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return nil
        }
        return nextValidFirstWarmup(after: startOfTomorrow.addingTimeInterval(-1), settings: settings)
    }

    private func event(
        for targetAt: Date,
        after now: Date,
        dayKey: String,
        windowNumber: Int
    ) -> ScheduledEvent? {
        switch position(of: targetAt, at: now) {
        case .scheduled:
            return ScheduledEvent(
                date: targetAt,
                targetAt: targetAt,
                dayKey: dayKey,
                windowNumber: windowNumber
            )
        case .actionable:
            return ScheduledEvent(
                date: now,
                targetAt: targetAt,
                dayKey: dayKey,
                windowNumber: windowNumber
            )
        case .missed:
            return nil
        }
    }

    // Sources: Korea AeroSpace Administration's official almanacs:
    // 2026: https://www.kasa.go.kr/prog/bbsArticle/BBSMSTR_000000000010/view.do?bbsId=BBSMSTR_000000000010&nttId=B000000001860Pe2zT3
    // 2027: https://www.kasa.go.kr/prog/plcyBrf/brief/kor/sub01_01_04/view.do?plcyBrfNo=431
    // The 2026 list includes Labor Day and Constitution Day, designated as public
    // holidays from 2026. The 2027 list includes their substitute holidays.
    private static let koreanHolidayDayKeys: Set<String> = [
        // 2026
        "2026-01-01",
        "2026-02-16", "2026-02-17", "2026-02-18",
        "2026-03-01", "2026-03-02",
        "2026-05-01", "2026-05-05", "2026-05-24", "2026-05-25",
        "2026-06-03", "2026-06-06",
        "2026-07-17",
        "2026-08-15", "2026-08-17",
        "2026-09-24", "2026-09-25", "2026-09-26",
        "2026-10-03", "2026-10-05", "2026-10-09",
        "2026-12-25",

        // 2027
        "2027-01-01",
        "2027-02-06", "2027-02-07", "2027-02-08", "2027-02-09",
        "2027-03-01",
        "2027-05-01", "2027-05-03", "2027-05-05", "2027-05-13",
        "2027-06-06",
        "2027-07-17", "2027-07-19",
        "2027-08-15", "2027-08-16",
        "2027-09-14", "2027-09-15", "2027-09-16",
        "2027-10-03", "2027-10-04", "2027-10-09", "2027-10-11",
        "2027-12-25", "2027-12-27",
    ]
}
