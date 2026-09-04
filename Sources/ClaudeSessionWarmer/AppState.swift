import AppKit
import Foundation
import ServiceManagement
import UserNotifications

enum ClaudeConnectionState: Equatable {
    case disconnected
    case checking
    case connected
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    static let quotaCacheLifetime: TimeInterval = 5 * 60

    @Published private(set) var settings: ScheduleSettings
    @Published private(set) var cycle: DailyCycle
    @Published private(set) var nextEvent: ScheduledEvent?
    @Published private(set) var currentQuota: QuotaWindow?
    @Published private(set) var status: WarmupStatus
    @Published private(set) var statusMessage: String
    @Published private(set) var isWorking = false
    @Published private(set) var isManualWarmupRunning = false
    @Published private(set) var connectionState: ClaudeConnectionState = .disconnected

    private let store: SettingsStore
    private let engine: ScheduleEngine
    private let lifecycleMonitor = LifecycleMonitor()
    private var timer: Timer?
    private var startedTargetsThisRun: Set<Date> = []
    private var isSilentRefreshRunning = false
    private var lastSilentRefreshAt: Date?

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
        if let cache = store.loadQuotaCache(), Self.isQuotaCacheFresh(cache, at: Date()) {
            currentQuota = cache.quota
            connectionState = .connected
            lastSilentRefreshAt = cache.fetchedAt
        }
        syncLaunchAtLoginStatus()
        diagnosticLogCritical("app.started", [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "start_scheduler": startScheduler ? "true" : "false",
            "day_key": savedCycle.dayKey ?? "none",
            "handled_windows": "\(savedCycle.handledWindows)",
            "next_reset_at": diagnosticDate(savedCycle.nextResetAt),
            "previous_status": savedCycle.lastRecord.map { String(describing: $0.status) } ?? "none"
        ])

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

    func connectClaude() {
        guard !isWorking, !isSilentRefreshRunning else { return }
        isWorking = true
        connectionState = .checking

        Task {
            do {
                let inspection = try await Self.loginManagedClaude()
                cacheQuota(inspection.quota)
                connectionState = .connected
                status = inspection.quota.active ? .satisfied : .idle
                statusMessage = "Claude에 연결했습니다."
            } catch {
                currentQuota = nil
                updateConnectionFailure(error)
                record(.failed, message: error.localizedDescription)
                store.saveDailyCycle(cycle)
            }
            isWorking = false
        }
    }

    func refreshSilently() {
        guard !isWorking, !isSilentRefreshRunning else { return }
        let now = Date()
        if let cache = store.loadQuotaCache(), Self.isQuotaCacheFresh(cache, at: now) {
            currentQuota = cache.quota
            connectionState = .connected
            lastSilentRefreshAt = cache.fetchedAt
            return
        }
        if let lastSilentRefreshAt,
           now.timeIntervalSince(lastSilentRefreshAt) < Self.quotaCacheLifetime {
            return
        }
        lastSilentRefreshAt = now
        isSilentRefreshRunning = true
        if connectionState != .connected {
            connectionState = .checking
        }

        Task {
            defer { isSilentRefreshRunning = false }
            do {
                let inspection = try await Self.inspectManagedClaude()
                cacheQuota(inspection.quota)
                connectionState = .connected
            } catch {
                if let serviceError = error as? ClaudeServiceError,
                   serviceError != .quotaRateLimited,
                   serviceError != .quotaUnavailable {
                    currentQuota = nil
                }
                updateConnectionFailure(error)
                if case .disconnected = connectionState, currentQuota == nil {
                    status = .idle
                    statusMessage = "Claude 연결이 필요합니다."
                }
            }
        }
    }

    func manualWarmup() {
        guard !isWorking else { return }
        isWorking = true
        isManualWarmupRunning = true
        let now = Date()
        let expectedReset = cycle.nextResetAt
        let belongsToActiveCycle = cycle.dayKey == engine.dayKey(for: now)
            && cycle.handledWindows > 0
            && cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay
            && expectedReset.map { now >= $0 } == true

        Task {
            var attemptedTarget: Date?
            do {
                var inspection = try await Self.inspectManagedClaude()
                var performedWarmup = false
                if !inspection.quota.active {
                    guard !hasRecentWarmupAttempt(at: now) else {
                        throw AppStateError.recentWarmupUnconfirmed
                    }
                    let target = belongsToActiveCycle ? expectedReset! : now
                    cycle.lastWarmupTargetAt = target
                    store.saveDailyCycle(cycle)
                    attemptedTarget = target
                    let warmupOperationID = UUID().uuidString
                    try await Self.runManagedWarmup(
                        cliURL: inspection.cliURL,
                        operationID: warmupOperationID
                    )
                    performedWarmup = true
                    inspection = try await Self.inspectManagedClaude()
                }
                guard inspection.quota.active, inspection.quota.resetsAt != nil else {
                    throw AppStateError.quotaNotActivated
                }

                cacheQuota(inspection.quota)
                connectionState = .connected
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
                updateConnectionFailure(error)
                if error as? ClaudeServiceError == .warmupNotStarted,
                   let attemptedTarget,
                   cycle.lastWarmupTargetAt == attemptedTarget {
                    cycle.lastWarmupTargetAt = nil
                }
                record(.failed, message: "수동 워밍 실패: \(error.localizedDescription)")
                store.saveDailyCycle(cycle)
            }
            isWorking = false
            isManualWarmupRunning = false
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
        guard let event = nextEvent else {
            diagnosticLog("schedule.selected", [
                "selected_at": diagnosticDate(now),
                "outcome": "none",
                "day_key": cycle.dayKey ?? "none",
                "handled_windows": "\(cycle.handledWindows)"
            ])
            return
        }
        var metadata = scheduledMetadata(event)
        metadata["selected_at"] = diagnosticDate(now)
        metadata["source"] = event.windowNumber == 1 ? "first" : "reset_or_fallback"
        metadata["handled_windows"] = "\(cycle.handledWindows)"
        diagnosticLog("schedule.selected", metadata)
        arm(event, at: event.date)
    }

    private func arm(_ event: ScheduledEvent, at date: Date) {
        timer?.invalidate()
        let delay = max(0.05, date.timeIntervalSinceNow)
        var metadata = scheduledMetadata(event)
        metadata["armed_for"] = diagnosticDate(date)
        metadata["delay_ms"] = "\(Int(delay * 1_000))"
        diagnosticLog("timer.armed", metadata)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                let firedAt = Date()
                var firedMetadata = self?.scheduledMetadata(event) ?? [:]
                firedMetadata["fired_at"] = diagnosticDate(firedAt)
                firedMetadata["drift_ms"] = "\(Int(firedAt.timeIntervalSince(date) * 1_000))"
                firedMetadata["was_working"] = self?.isWorking == true ? "true" : "false"
                diagnosticLogCritical("timer.fired", firedMetadata)
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
            var quotaOperationID = UUID().uuidString
            do {
                var inspection = try await Self.inspectManagedClaude(operationID: quotaOperationID)
                connectionState = .connected
                logQuotaDecision(
                    inspection.quota,
                    phase: "scheduled_pre",
                    operationID: inspection.operationID,
                    event: event
                )
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
                    var warmupMetadata = scheduledMetadata(event)
                    let warmupOperationID = UUID().uuidString
                    warmupMetadata["context"] = "scheduled"
                    warmupMetadata["operation_id"] = warmupOperationID
                    diagnosticLog("warmup.requested", warmupMetadata)
                    try await Self.runManagedWarmup(
                        cliURL: inspection.cliURL,
                        operationID: warmupOperationID
                    )
                    quotaOperationID = UUID().uuidString
                    inspection = try await Self.inspectManagedClaude(operationID: quotaOperationID)
                    logQuotaDecision(
                        inspection.quota,
                        phase: "scheduled_post",
                        operationID: inspection.operationID,
                        event: event
                    )
                    guard isFreshWindow(inspection.quota, for: event) else {
                        throw AppStateError.quotaNotActivated
                    }
                    complete(event, quota: inspection.quota, status: .succeeded, message: "워밍이 완료되었습니다.")
                }
            } catch {
                var failureMetadata = scheduledMetadata(event)
                failureMetadata["operation_id"] = quotaOperationID
                failureMetadata["error_code"] = diagnosticErrorCode(error)
                diagnosticLog("window.attempt_failed", failureMetadata)
                updateConnectionFailure(error)
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
        cacheQuota(quota)
        cycle.handledWindows = min(
            max(cycle.handledWindows, event.windowNumber),
            ScheduleEngine.maximumWindowsPerDay
        )
        cycle.nextResetAt = cycle.handledWindows < ScheduleEngine.maximumWindowsPerDay
            ? quota.resetsAt
            : nil
        record(completedStatus, message: message)
        store.saveDailyCycle(cycle)
        var metadata = scheduledMetadata(event)
        metadata["outcome"] = completedStatus == .succeeded ? "warmed" : "already_active"
        metadata["actual_reset_at"] = diagnosticDate(quota.resetsAt)
        metadata["handled_windows"] = "\(cycle.handledWindows)"
        metadata["next_target_at"] = diagnosticDate(cycle.nextResetAt)
        diagnosticLogCritical("window.completed", metadata)
        startedTargetsThisRun.remove(event.targetAt)
        scheduleNext(after: Date().addingTimeInterval(0.1))
    }

    private func handleTargetFailure(_ error: Error, event: ScheduledEvent) {
        let expiresAt = engine.timing(for: event.targetAt).expiresAt
        let retryAt = Date().addingTimeInterval(30)
        record(.failed, message: "워밍 확인 실패: \(error.localizedDescription)")
        store.saveDailyCycle(cycle)

        if retryAt <= expiresAt {
            var metadata = scheduledMetadata(event)
            metadata["retry_at"] = diagnosticDate(retryAt)
            metadata["deadline_at"] = diagnosticDate(expiresAt)
            metadata["error_code"] = diagnosticErrorCode(error)
            diagnosticLog("window.retry_armed", metadata)
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
        diagnosticLogCritical("window.unresolved", [
            "target_at": diagnosticDate(targetAt),
            "window": "\(windowNumber)",
            "outcome": String(describing: newStatus),
            "fallback_at": diagnosticDate(cycle.nextResetAt),
            "handled_windows": "\(cycle.handledWindows)"
        ])
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

    private func scheduledMetadata(_ event: ScheduledEvent) -> [String: String] {
        [
            "day_key": event.dayKey,
            "window": "\(event.windowNumber)",
            "target_at": diagnosticDate(event.targetAt),
            "event_at": diagnosticDate(event.date)
        ]
    }

    static func isQuotaCacheFresh(_ cache: QuotaCache, at now: Date) -> Bool {
        let age = now.timeIntervalSince(cache.fetchedAt)
        return age >= 0 && age < quotaCacheLifetime
    }

    private func cacheQuota(_ quota: QuotaWindow) {
        currentQuota = quota
        store.saveQuotaCache(QuotaCache(quota: quota, fetchedAt: Date()))
    }

    private func logQuotaDecision(
        _ quota: QuotaWindow,
        phase: String,
        operationID: String,
        event: ScheduledEvent? = nil
    ) {
        var metadata = event.map(scheduledMetadata) ?? [:]
        metadata["phase"] = phase
        metadata["operation_id"] = operationID
        metadata["active"] = quota.active ? "true" : "false"
        metadata["used_percent"] = quota.usedPercent.map { String($0) } ?? "none"
        metadata["resets_at"] = diagnosticDate(quota.resetsAt)
        diagnosticLog("quota.decision", metadata)
    }

    private func diagnosticErrorCode(_ error: Error) -> String {
        if error is ClaudeServiceError {
            return ClaudeService.diagnosticErrorCode(error)
        }
        guard let error = error as? AppStateError else { return "unexpected" }
        switch error {
        case .quotaNotReset: return "quota_not_reset"
        case .quotaNotActivated: return "quota_not_activated"
        case .recentWarmupUnconfirmed: return "recent_warmup_unconfirmed"
        }
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

    private func updateConnectionFailure(_ error: Error) {
        if error is AppStateError { return }
        guard let serviceError = error as? ClaudeServiceError else {
            connectionState = .failed(error.localizedDescription)
            return
        }
        if serviceError == .managedCredentialsUnavailable {
            connectionState = .disconnected
        } else if serviceError == .quotaRateLimited
                    || serviceError == .quotaUnavailable
                    || serviceError == .invalidUsageResponse {
            if connectionState == .checking {
                connectionState = .connected
            }
        } else if serviceError != .warmupNotStarted,
                    serviceError != .warmupTimedOut,
                    serviceError != .warmupFailed {
            connectionState = .failed(error.localizedDescription)
        }
    }

    private static func inspectManagedClaude(
        operationID: String = UUID().uuidString
    ) async throws -> Inspection {
        return try await Task.detached(priority: .utility) {
            try await DiagnosticContext.$operationID.withValue(operationID) {
                let service = ClaudeService()
                let cliURL = try service.locateCLI()
                let quota = try await service.fetchManagedQuota()
                return Inspection(cliURL: cliURL, quota: quota, operationID: operationID)
            }
        }.value
    }

    private static func loginManagedClaude() async throws -> Inspection {
        let operationID = UUID().uuidString
        return try await Task.detached(priority: .userInitiated) {
            try await DiagnosticContext.$operationID.withValue(operationID) {
                let service = ClaudeService()
                let cliURL = try service.locateCLI()
                _ = try await service.loginAndCapture(cliURL: cliURL)
                let quota = try await service.fetchManagedQuota()
                return Inspection(cliURL: cliURL, quota: quota, operationID: operationID)
            }
        }.value
    }

    private static func runManagedWarmup(cliURL: URL, operationID: String) async throws {
        try await Task.detached(priority: .utility) {
            try DiagnosticContext.$operationID.withValue(operationID) {
                let service = ClaudeService()
                let token = try service.managedAccessToken()
                try service.performWarmup(
                    command: ClaudeWarmupCommand.make(executableURL: cliURL, oauthToken: token)
                )
            }
        }.value
    }
}

private struct Inspection: Sendable {
    let cliURL: URL
    let quota: QuotaWindow
    let operationID: String
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
