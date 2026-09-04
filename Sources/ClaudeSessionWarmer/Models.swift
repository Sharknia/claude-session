import Foundation

struct ScheduleSettings: Codable, Equatable, Sendable {
    /// Minutes after midnight in the user's current time zone.
    var firstWarmupMinutes: Int

    /// `Calendar.Component.weekday` values: Sunday is 1 and Saturday is 7.
    var weekdays: Set<Int>
    var excludeKoreanHolidays: Bool
    var launchAtLogin: Bool

    init(
        firstWarmupMinutes: Int = 6 * 60,
        weekdays: Set<Int> = [2, 3, 4, 5, 6],
        excludeKoreanHolidays: Bool = true,
        launchAtLogin: Bool = false
    ) {
        self.firstWarmupMinutes = firstWarmupMinutes
        self.weekdays = weekdays
        self.excludeKoreanHolidays = excludeKoreanHolidays
        self.launchAtLogin = launchAtLogin
    }
}

enum WarmupStatus: String, Codable, Equatable, Sendable {
    case idle
    case checking
    case warming
    case satisfied
    case succeeded
    case missed
    case failed
}

struct QuotaWindow: Codable, Equatable, Sendable {
    var active: Bool
    var usedPercent: Double?
    var resetsAt: Date?
}

struct QuotaCache: Codable, Equatable, Sendable {
    var quota: QuotaWindow
    var fetchedAt: Date
}

struct WarmupRecord: Codable, Equatable, Sendable {
    var timestamp: Date
    var status: WarmupStatus
    var message: String
}

struct DailyCycle: Codable, Equatable, Sendable {
    var dayKey: String?
    var handledWindows: Int
    var nextResetAt: Date?
    var lastWarmupTargetAt: Date?
    var lastRecord: WarmupRecord?

    init(
        dayKey: String? = nil,
        handledWindows: Int = 0,
        nextResetAt: Date? = nil,
        lastWarmupTargetAt: Date? = nil,
        lastRecord: WarmupRecord? = nil
    ) {
        self.dayKey = dayKey
        self.handledWindows = min(max(handledWindows, 0), 3)
        self.nextResetAt = nextResetAt
        self.lastWarmupTargetAt = lastWarmupTargetAt
        self.lastRecord = lastRecord
    }
}
