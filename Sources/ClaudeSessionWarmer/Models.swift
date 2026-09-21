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

    var displayMessage: String {
        if status == .satisfied, message == "이미 열린 창을 확인했습니다." {
            return "이미 세션이 활성화되었습니다."
        }
        return message
    }
}

struct ScheduledWindowFailure: Codable, Equatable, Sendable {
    var targetAt: Date
    var message: String
    var attempts: Int?
    var retryAt: Date?
    var keychainAccessFailure: Bool?
}

struct DailyCycle: Codable, Equatable, Sendable {
    var dayKey: String?
    var handledWindows: Int
    var nextResetAt: Date?
    var lastWarmupTargetAt: Date?
    var lastRecord: WarmupRecord?
    var firstFailure: ScheduledWindowFailure?
    var lastConfirmedResetAt: Date?
    var lastWarmupAttemptAt: Date?
    /// 복구일의 불확실한 횟수는 성공으로 계산하지 않고 자동 실행만 중지한다.
    var recoveryHoldDayKey: String?

    init(
        dayKey: String? = nil,
        handledWindows: Int = 0,
        nextResetAt: Date? = nil,
        lastWarmupTargetAt: Date? = nil,
        lastRecord: WarmupRecord? = nil,
        firstFailure: ScheduledWindowFailure? = nil,
        lastConfirmedResetAt: Date? = nil,
        lastWarmupAttemptAt: Date? = nil,
        recoveryHoldDayKey: String? = nil
    ) {
        self.dayKey = dayKey
        self.handledWindows = min(max(handledWindows, 0), 3)
        self.nextResetAt = nextResetAt
        self.lastWarmupTargetAt = lastWarmupTargetAt
        self.lastRecord = lastRecord
        self.firstFailure = firstFailure
        self.lastConfirmedResetAt = lastConfirmedResetAt
        self.lastWarmupAttemptAt = lastWarmupAttemptAt
        self.recoveryHoldDayKey = recoveryHoldDayKey
    }
}

enum StoredValueError: Error {
    case invalid(String)
}

extension ScheduleSettings {
    func validate() throws {
        guard (0...1439).contains(firstWarmupMinutes), !weekdays.isEmpty,
              weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw StoredValueError.invalid("예약 시각 또는 요일이 올바르지 않습니다.")
        }
    }
}

extension Date {
    fileprivate var isValidStoredDate: Bool {
        timeIntervalSince1970.isFinite && (-62_135_596_800...253_402_300_799).contains(timeIntervalSince1970)
    }
}

extension DailyCycle {
    func validate() throws {
        guard (0...3).contains(handledWindows), (firstFailure?.attempts ?? 0) >= 0 else {
            throw StoredValueError.invalid("완료 또는 재시도 횟수가 올바르지 않습니다.")
        }
        guard handledWindows == 0 || dayKey != nil else {
            throw StoredValueError.invalid("완료 횟수의 실행 날짜가 없습니다.")
        }
        guard recoveryHoldDayKey == nil || recoveryHoldDayKey == dayKey else {
            throw StoredValueError.invalid("복구 중지 날짜와 실행 날짜가 일치하지 않습니다.")
        }
        if let dayKey {
            let parts = dayKey.split(separator: "-", omittingEmptySubsequences: false)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  let year = Int(parts[0]), (1...9999).contains(year),
                  let month = Int(parts[1]), let day = Int(parts[2]),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.year, from: date) == year,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else {
                throw StoredValueError.invalid("실행 날짜가 올바르지 않습니다.")
            }
        }
        let dates = [nextResetAt, lastWarmupTargetAt, lastRecord?.timestamp,
                     firstFailure?.targetAt, firstFailure?.retryAt, lastConfirmedResetAt, lastWarmupAttemptAt]
        guard dates.compactMap({ $0 }).allSatisfy(\.isValidStoredDate),
              lastWarmupAttemptAt == nil || lastWarmupTargetAt != nil else {
            throw StoredValueError.invalid("실행 시각 또는 미확인 전송 기록이 올바르지 않습니다.")
        }
        if let failure = firstFailure, let retry = failure.retryAt, retry < failure.targetAt {
            throw StoredValueError.invalid("재시도 시각이 대상 시각보다 빠릅니다.")
        }
        if let attempt = lastWarmupAttemptAt, let target = lastWarmupTargetAt, attempt < target {
            throw StoredValueError.invalid("전송 시각이 대상 시각보다 빠릅니다.")
        }
    }
}

extension QuotaCache {
    var isValid: Bool {
        fetchedAt.isValidStoredDate
            && (quota.resetsAt?.isValidStoredDate ?? true)
            && (quota.usedPercent.map { $0.isFinite && (0...100).contains($0) } ?? true)
            && (!quota.active || quota.resetsAt != nil)
    }
}
