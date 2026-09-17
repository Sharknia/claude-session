import Foundation

struct ScheduledEvent: Equatable, Sendable {
    let date: Date
    let targetAt: Date
    let dayKey: String
    let windowNumber: Int
}

/// Pure date calculations for the MVP scheduler.
///
/// This type deliberately does not own a timer or perform any I/O. Its caller asks
/// for one event, schedules it, updates `DailyCycle`, and asks again.
struct ScheduleEngine: Sendable {
    static let maximumWindowsPerDay = 3
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

    /// 오늘의 미완료 작업 하나를 선택한다. 지연은 실행 자격을 만료시키지 않는다.
    func nextEvent(
        after now: Date,
        settings: ScheduleSettings,
        cycle: DailyCycle
    ) -> ScheduledEvent? {
        let today = dayKey(for: now)
        let sameDay = cycle.dayKey == today
        let count = sameDay ? cycle.handledWindows : 0
        if let first = firstWarmup(on: now, settings: settings), count < Self.maximumWindowsPerDay {
            let target = count == 0 ? first : (cycle.nextResetAt ?? first)
            let failure = sameDay ? cycle.firstFailure : nil
            let paused = failure?.targetAt == target && failure?.retryAt == nil
            if dayKey(for: target) == today, !paused {
                let retryAt = failure?.targetAt == target ? failure?.retryAt : nil
                return ScheduledEvent(
                    date: max(now, first, target, retryAt ?? target), targetAt: target,
                    dayKey: today, windowNumber: count + 1
                )
            }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        guard let first = nextValidFirstWarmup(after: tomorrow.addingTimeInterval(-1), settings: settings) else {
            return nil
        }
        return ScheduledEvent(date: first, targetAt: first, dayKey: dayKey(for: first), windowNumber: 1)
    }

    func newCycle(startingAt firstWarmup: Date) -> DailyCycle {
        DailyCycle(dayKey: dayKey(for: firstWarmup))
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
