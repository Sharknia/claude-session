import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings: ScheduleSettings
    @Published private(set) var cycle: DailyCycle
    @Published private(set) var nextEvent: ScheduledEvent?
    @Published private(set) var currentQuota: QuotaWindow?
    @Published private(set) var status: WarmupStatus
    @Published private(set) var statusMessage: String
    @Published private(set) var isWorking = false

    private let store: SettingsStore
    private let engine: ScheduleEngine
    private var timer: Timer?
    private var startedTargetsThisRun: Set<Date> = []

    init(
        store: SettingsStore = SettingsStore(),
        engine: ScheduleEngine = ScheduleEngine(),
        startScheduler: Bool = true
    ) {
        let savedCycle = store.loadDailyCycle()
        self.store = store
        self.engine = engine
        settings = store.loadSettings()
        cycle = savedCycle
        status = savedCycle.lastRecord?.status ?? .idle
        statusMessage = savedCycle.lastRecord?.message ?? "대기 중"
        syncLaunchAtLoginStatus()

        if startScheduler {
            scheduleNext()
        }
    }

    var firstWarmupDate: Date {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: settings.firstWarmupMinutes, to: start) ?? start
    }

    var handledWindowsToday: Int {
        cycle.dayKey == engine.dayKey(for: Date()) ? cycle.handledWindows : 0
    }

    @discardableResult
    func applySettings(
        firstWarmupDate: Date,
        weekdays: Set<Int>,
        excludeKoreanHolidays: Bool,
        launchAtLogin: Bool
    ) -> Bool {
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
            return false
        }
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: firstWarmupDate
        )
        settings.firstWarmupMinutes = min(
            max((components.hour ?? 0) * 60 + (components.minute ?? 0), 0),
            23 * 60 + 59
        )
        settings.weekdays = weekdays
        settings.excludeKoreanHolidays = excludeKoreanHolidays
        applyLaunchAtLogin(launchAtLogin)
        store.saveSettings(settings)
        scheduleNext()
        return true
    }

    @discardableResult
    func prepareAndApplySettings(
        firstWarmupDate: Date,
        weekdays: Set<Int>,
        excludeKoreanHolidays: Bool,
        launchAtLogin: Bool
    ) async -> Bool {
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }), !isWorking else {
            return false
        }

        isWorking = true
        status = .checking
        statusMessage = "자동 실행 권한 준비 중"
        defer { isWorking = false }

        do {
            let inspection = try await Self.inspectForCredentialPreparation()
            currentQuota = inspection.quota
        } catch {
            record(.failed, message: "설정 저장 실패: \(error.localizedDescription)")
            store.saveDailyCycle(cycle)
            return false
        }

        let applied = applySettings(
            firstWarmupDate: firstWarmupDate,
            weekdays: weekdays,
            excludeKoreanHolidays: excludeKoreanHolidays,
            launchAtLogin: launchAtLogin
        )
        let loginSettingApplied = settings.launchAtLogin == launchAtLogin
        if applied, loginSettingApplied {
            status = .idle
            statusMessage = "설정과 자동 실행 권한을 저장했습니다."
        }
        return applied && loginSettingApplied
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            let currentStatus = SMAppService.mainApp.status
            if enabled, currentStatus == .notRegistered {
                try SMAppService.mainApp.register()
            } else if !enabled,
                      currentStatus == .enabled || currentStatus == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            let serviceStatus = SMAppService.mainApp.status
            settings.launchAtLogin = serviceStatus == .enabled
            store.saveSettings(settings)
            if enabled, serviceStatus == .requiresApproval {
                record(.failed, message: "시스템 설정의 로그인 항목에서 앱을 허용해 주세요.")
                store.saveDailyCycle(cycle)
            } else if enabled, serviceStatus != .enabled {
                record(.failed, message: "로그인 실행을 활성화하지 못했습니다.")
                store.saveDailyCycle(cycle)
            }
        } catch {
            record(.failed, message: "로그인 실행 설정 실패: \(error.localizedDescription)")
            store.saveDailyCycle(cycle)
            notifyFailure(statusMessage)
        }
    }

    func refresh() {
        guard !isWorking else { return }
        isWorking = true
        status = .checking
        statusMessage = "Claude 상태 확인 중"

        Task {
            do {
                let inspection = try await Self.inspectClaude(allowsCredentialPrompt: true)
                currentQuota = inspection.quota
                status = inspection.quota.active ? .satisfied : .idle
                statusMessage = inspection.quota.active ? "활성 사용량 창을 확인했습니다." : "활성 사용량 창이 없습니다."
            } catch {
                record(.failed, message: error.localizedDescription)
                store.saveDailyCycle(cycle)
                notifyFailure(statusMessage)
            }
            isWorking = false
        }
    }

    func manualWarmup() {
        guard !isWorking else { return }
        isWorking = true
        status = .checking
        statusMessage = "수동 워밍 준비 중"
        let now = Date()
        let expectedReset = cycle.nextResetAt
        let belongsToActiveCycle = cycle.dayKey == engine.dayKey(for: now)
            && cycle.handledWindows > 0
            && cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay
            && expectedReset.map { now >= $0 } == true

        Task {
            var attemptedTarget: Date?
            do {
                var inspection = try await Self.inspectClaude(allowsCredentialPrompt: true)
                var performedWarmup = false
                if !inspection.quota.active {
                    guard !hasRecentWarmupAttempt(at: now) else {
                        throw AppStateError.recentWarmupUnconfirmed
                    }
                    let target = belongsToActiveCycle ? expectedReset! : now
                    cycle.lastWarmupTargetAt = target
                    store.saveDailyCycle(cycle)
                    attemptedTarget = target
                    status = .warming
                    statusMessage = "Claude 워밍 중"
                    try await Self.runWarmup(cliURL: inspection.cliURL)
                    performedWarmup = true
                    inspection = try await Self.inspectClaude(allowsCredentialPrompt: true)
                }
                guard inspection.quota.active, inspection.quota.resetsAt != nil else {
                    throw AppStateError.quotaNotActivated
                }

                currentQuota = inspection.quota
                if belongsToActiveCycle {
                    cycle.handledWindows = min(cycle.handledWindows + 1, ScheduleEngine.maximumWindowsPerDay)
                    cycle.nextResetAt = cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay
                        ? inspection.quota.resetsAt
                        : nil
                    store.saveDailyCycle(cycle)
                }
                record(
                    performedWarmup ? .succeeded : .satisfied,
                    message: "수동 워밍을 확인했습니다."
                )
                store.saveDailyCycle(cycle)
                scheduleNext()
            } catch {
                if error as? ClaudeServiceError == .warmupNotStarted,
                   let attemptedTarget,
                   cycle.lastWarmupTargetAt == attemptedTarget {
                    cycle.lastWarmupTargetAt = nil
                }
                record(.failed, message: "수동 워밍 실패: \(error.localizedDescription)")
                store.saveDailyCycle(cycle)
                notifyFailure(statusMessage)
            }
            isWorking = false
        }
    }

    private func syncLaunchAtLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if settings.launchAtLogin != enabled {
            settings.launchAtLogin = enabled
            store.saveSettings(settings)
        }
    }

    private func scheduleNext(after now: Date = Date()) {
        timer?.invalidate()
        reconcileMissedWindows(at: now)
        nextEvent = engine.nextEvent(after: now, settings: settings, cycle: cycle)
        guard let event = nextEvent else { return }
        arm(event, at: event.date)
    }

    private func arm(_ event: ScheduledEvent, at date: Date) {
        timer?.invalidate()
        let delay = max(0.05, date.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: ScheduledEvent) {
        guard !isWorking else {
            arm(event, at: Date().addingTimeInterval(5))
            return
        }
        let now = Date()
        if engine.position(of: event.targetAt, at: now) == .missed {
            closeMissed(event)
            return
        }
        let isLateBeyondTimerJitter = now.timeIntervalSince(event.targetAt) > 5
        let hasStartedAttempt = hasStartedEvent(event)
        if isLateBeyondTimerJitter, !hasStartedAttempt {
            closeMissed(event)
            return
        }

        performScheduledWarmup(for: event)
    }

    private func performScheduledWarmup(for event: ScheduledEvent) {
        if event.windowNumber == 1, cycle.dayKey != event.dayKey {
            cycle = engine.newCycle(startingAt: event.targetAt)
            store.saveDailyCycle(cycle)
        }

        markScheduledWindowStarted(event)

        isWorking = true
        status = .checking
        statusMessage = "\(event.windowNumber)번째 창 확인 중"

        Task {
            do {
                var inspection = try await Self.inspectClaude(allowsCredentialPrompt: false)
                if isFreshWindow(inspection.quota, for: event) {
                    complete(event, quota: inspection.quota, status: .satisfied, message: "이미 열린 창을 확인했습니다.")
                } else if inspection.quota.active {
                    throw AppStateError.quotaNotReset
                } else if shouldSuppressWarmup(for: event.targetAt, at: Date()) {
                    throw AppStateError.quotaNotActivated
                } else {
                    cycle.lastWarmupTargetAt = event.targetAt
                    store.saveDailyCycle(cycle)
                    status = .warming
                    statusMessage = "\(event.windowNumber)번째 창 워밍 중"
                    try await Self.runWarmup(cliURL: inspection.cliURL)
                    inspection = try await Self.inspectClaude(allowsCredentialPrompt: false)
                    guard isFreshWindow(inspection.quota, for: event) else {
                        throw AppStateError.quotaNotActivated
                    }
                    complete(event, quota: inspection.quota, status: .succeeded, message: "워밍이 완료되었습니다.")
                }
            } catch {
                if error as? ClaudeServiceError == .warmupNotStarted,
                   cycle.lastWarmupTargetAt == event.targetAt {
                    cycle.lastWarmupTargetAt = nil
                    store.saveDailyCycle(cycle)
                }
                handleTargetFailure(error, event: event)
            }
            isWorking = false
        }
    }

    func markScheduledWindowStarted(_ event: ScheduledEvent) {
        startedTargetsThisRun.insert(event.targetAt)
        cycle.nextResetAt = event.targetAt
        record(.checking, message: "\(event.windowNumber)번째 창 확인 시작")
        store.saveDailyCycle(cycle)
    }

    private func hasStartedEvent(_ event: ScheduledEvent) -> Bool {
        if startedTargetsThisRun.contains(event.targetAt)
            || cycle.lastWarmupTargetAt == event.targetAt {
            return true
        }
        guard
            cycle.nextResetAt == event.targetAt,
            let record = cycle.lastRecord,
            record.status == .checking || record.status == .failed,
            let startedAt = cycle.lastRecord?.timestamp
        else { return false }
        return (-5...ScheduleEngine.windowTolerance).contains(
            startedAt.timeIntervalSince(event.targetAt)
        )
    }

    private func isFreshWindow(_ quota: QuotaWindow, for event: ScheduledEvent) -> Bool {
        guard quota.active, let resetsAt = quota.resetsAt else { return false }
        return event.windowNumber == 1 || resetsAt > event.targetAt
    }

    private func complete(
        _ event: ScheduledEvent,
        quota: QuotaWindow,
        status completedStatus: WarmupStatus,
        message: String
    ) {
        currentQuota = quota
        cycle.handledWindows = min(
            max(cycle.handledWindows, event.windowNumber),
            ScheduleEngine.maximumWindowsPerDay
        )
        cycle.nextResetAt = cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay
            ? quota.resetsAt
            : nil
        record(completedStatus, message: message)
        store.saveDailyCycle(cycle)
        startedTargetsThisRun.remove(event.targetAt)
        scheduleNext(after: Date().addingTimeInterval(0.1))
    }

    private func handleTargetFailure(_ error: Error, event: ScheduledEvent) {
        let expiresAt = engine.timing(for: event.targetAt).expiresAt
        let retryAt = Date().addingTimeInterval(30)
        record(.failed, message: "워밍 확인 실패: \(error.localizedDescription)")
        store.saveDailyCycle(cycle)

        if retryAt <= expiresAt {
            let retryEvent = ScheduledEvent(
                date: retryAt,
                targetAt: event.targetAt,
                dayKey: event.dayKey,
                windowNumber: event.windowNumber
            )
            nextEvent = retryEvent
            arm(retryEvent, at: retryAt)
            return
        }

        advanceAfterUnresolvedWindow(
            targetAt: event.targetAt,
            windowNumber: event.windowNumber,
            status: .failed,
            message: "워밍 확인 실패: \(error.localizedDescription)"
        )
        notifyFailure(statusMessage)
        scheduleNext(after: Date().addingTimeInterval(0.1))
    }

    private func closeMissed(_ event: ScheduledEvent) {
        if event.windowNumber == 1, cycle.dayKey != event.dayKey {
            cycle = engine.newCycle(startingAt: event.targetAt)
        }
        advanceAfterUnresolvedWindow(
            targetAt: event.targetAt,
            windowNumber: event.windowNumber,
            status: .missed,
            message: "예약 시각을 놓쳐 해당 창은 따라잡지 않습니다."
        )
        scheduleNext(after: Date().addingTimeInterval(0.1))
    }

    func reconcileMissedWindows(at now: Date) {
        let todayKey = engine.dayKey(for: now)
        if let firstTarget = engine.firstWarmup(on: now, settings: settings), firstTarget < now {
            if cycle.dayKey != todayKey {
                cycle = engine.newCycle(startingAt: firstTarget)
                advanceAfterUnresolvedWindow(
                    targetAt: firstTarget,
                    windowNumber: 1,
                    status: .missed,
                    message: "첫 워밍 시각을 놓쳐 해당 창은 따라잡지 않습니다."
                )
            }
        }

        while let resetAt = cycle.nextResetAt,
              cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay,
              engine.dayKey(for: resetAt) == cycle.dayKey,
              engine.position(of: resetAt, at: now) == .missed {
            advanceAfterUnresolvedWindow(
                targetAt: resetAt,
                windowNumber: cycle.handledWindows + 1,
                status: .missed,
                message: "리셋 시각을 놓쳐 해당 창은 따라잡지 않습니다."
            )
        }
    }

    func advanceAfterUnresolvedWindow(
        targetAt: Date,
        windowNumber: Int,
        status newStatus: WarmupStatus,
        message: String
    ) {
        cycle.handledWindows = min(
            max(cycle.handledWindows, windowNumber),
            ScheduleEngine.maximumWindowsPerDay
        )
        cycle.nextResetAt = cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay
            ? targetAt.addingTimeInterval(ScheduleEngine.quotaWindowDuration)
            : nil
        startedTargetsThisRun.remove(targetAt)
        record(newStatus, message: message)
        store.saveDailyCycle(cycle)
    }

    func hasRecentWarmupAttempt(at now: Date) -> Bool {
        guard let target = cycle.lastWarmupTargetAt else { return false }
        return (0...ScheduleEngine.windowTolerance).contains(now.timeIntervalSince(target))
    }

    func shouldSuppressWarmup(for targetAt: Date, at now: Date) -> Bool {
        guard let lastTarget = cycle.lastWarmupTargetAt else { return false }
        return lastTarget == targetAt
            || abs(targetAt.timeIntervalSince(lastTarget)) <= ScheduleEngine.windowTolerance
            || (0...ScheduleEngine.windowTolerance).contains(now.timeIntervalSince(lastTarget))
    }

    private func record(_ newStatus: WarmupStatus, message: String) {
        status = newStatus
        statusMessage = message
        cycle.lastRecord = WarmupRecord(timestamp: Date(), status: newStatus, message: message)
    }

    private func notifyFailure(_ message: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert])) == true
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "Claude Session Warmer"
            content.body = message
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func inspectForCredentialPreparation() async throws -> Inspection {
        do {
            return try await inspectClaude(allowsCredentialPrompt: false)
        } catch let error as ClaudeServiceError
            where error == .credentialsRequireManualRefresh || error == .quotaUnauthorized {
            return try await inspectClaude(allowsCredentialPrompt: true)
        }
    }

    private static func inspectClaude(allowsCredentialPrompt: Bool) async throws -> Inspection {
        try await Task.detached(priority: .utility) {
            let service = ClaudeService()
            let cliURL = try service.locateCLI()
            _ = try service.checkAuth(cliURL: cliURL)
            let token = try service.readAccessToken(allowsInteraction: allowsCredentialPrompt)
            let quota = try await service.fetchQuota(accessToken: token)
            return Inspection(cliURL: cliURL, quota: quota)
        }.value
    }

    private static func runWarmup(cliURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let service = ClaudeService()
            try service.performWarmup(command: ClaudeWarmupCommand.make(executableURL: cliURL))
        }.value
    }
}

private struct Inspection: Sendable {
    let cliURL: URL
    let quota: QuotaWindow
}

private enum AppStateError: LocalizedError {
    case quotaNotReset
    case quotaNotActivated
    case recentWarmupUnconfirmed

    var errorDescription: String? {
        switch self {
        case .quotaNotReset:
            return "이전 사용량 창이 아직 종료되지 않았습니다."
        case .quotaNotActivated:
            return "워밍 후 새 사용량 창을 확인하지 못했습니다."
        case .recentWarmupUnconfirmed:
            return "최근 워밍 결과가 아직 확인되지 않아 다시 호출하지 않습니다."
        }
    }
}
