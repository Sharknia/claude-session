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
    private let schedulerEnabled: Bool
    private let clock: @Sendable () -> Date
    private let confirmationSleep: @Sendable (Duration) async throws -> Void
    private let inspectClaude: @Sendable (String) async throws -> Inspection
    private let warmClaude: @Sendable (URL, String) async throws -> Void
    private var lifecycleMonitor: LifecycleMonitor?
    private var timer: WallClockTimer?
    private(set) var scheduledTimerID: UUID?
    private var needsFreshSchedule = false
    private var pendingScheduleReasons: Set<String> = []
    private var scheduleRevision = 0
    private var isSilentRefreshRunning = false
    private var lastSilentRefreshAt: Date?

    init(
        store: SettingsStore = SettingsStore(),
        engine: ScheduleEngine = ScheduleEngine(),
        startScheduler: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() },
        inspectClaude: (@Sendable (String) async throws -> Inspection)? = nil,
        warmClaude: (@Sendable (URL, String) async throws -> Void)? = nil,
        confirmationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        var savedCycle = store.loadDailyCycle()
        // 구버전 횟수는 당일 상한으로 보존한다. 확인된 성공의 전송 표식만 정리한다.
        if savedCycle.lastWarmupAttemptAt == nil,
           savedCycle.lastRecord?.status == .succeeded || savedCycle.lastRecord?.status == .satisfied {
            savedCycle.lastConfirmedResetAt = savedCycle.lastConfirmedResetAt ?? savedCycle.nextResetAt
            savedCycle.lastWarmupTargetAt = nil
            savedCycle.lastWarmupAttemptAt = nil
        }
        self.store = store
        self.engine = engine
        self.schedulerEnabled = startScheduler
        self.clock = clock
        self.confirmationSleep = confirmationSleep
        self.inspectClaude = inspectClaude ?? { try await Self.inspectManagedClaude(operationID: $0) }
        self.warmClaude = warmClaude ?? { try await Self.runManagedWarmup(cliURL: $0, operationID: $1) }
        settings = store.loadSettings()
        cycle = savedCycle
        status = savedCycle.lastRecord?.status ?? .idle
        statusMessage = savedCycle.lastRecord?.displayMessage ?? "대기 중"
        if let cache = store.loadQuotaCache(), Self.isQuotaCacheFresh(cache, at: Date()) {
            currentQuota = cache.quota
            connectionState = .connected
            lastSilentRefreshAt = cache.fetchedAt
        }
        syncLaunchAtLoginStatus()
        diagnosticLogCritical("app.started", [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "start_scheduler": startScheduler ? "true" : "false",
            "day_key": savedCycle.dayKey ?? "none",
            "handled_windows": "\(savedCycle.handledWindows)",
            "next_reset_at": diagnosticDate(savedCycle.nextResetAt),
            "previous_status": savedCycle.lastRecord.map { String(describing: $0.status) } ?? "none"
        ])

        if startScheduler {
            lifecycleMonitor = LifecycleMonitor { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.reconcileSchedule(reason: reason)
                }
            }
            reconcileSchedule(reason: "startup")
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
        scheduleRevision += 1
        scheduleNext(reason: "settings_changed")
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
            defer { finishWorking() }
            do {
                let inspection = try await Self.loginManagedClaude()
                cacheQuota(inspection.quota)
                connectionState = .connected
                status = inspection.quota.active ? .satisfied : .idle
                statusMessage = "Claude에 연결했습니다."
                reconcileSchedule(reason: "login_completed")
            } catch {
                currentQuota = nil
                updateConnectionFailure(error)
                record(.failed, message: error.localizedDescription)
                store.saveDailyCycle(cycle)
            }
        }
    }

    func refreshSilently() {
        guard !isWorking, !isSilentRefreshRunning else { return }
        let now = clock()
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

    var hasUnconfirmedWarmup: Bool { cycle.lastWarmupTargetAt != nil }

    func manualWarmup(allowResend: Bool = false) {
        guard !isWorking else { return }
        if allowResend {
            cycle.lastWarmupTargetAt = nil
            cycle.lastWarmupAttemptAt = nil
            store.saveDailyCycle(cycle)
        }
        let now = clock()
        var candidateCycle = cycle
        candidateCycle.firstFailure = nil // 명시적인 수동 재시도는 자동 재시도 상한을 다시 연다.
        let candidate = engine.nextEvent(after: now, settings: settings, cycle: candidateCycle)
        let event = candidate.flatMap { $0.date <= now ? $0 : nil }
        if let event {
            cycle.firstFailure = nil
            markScheduledWindowStarted(event)
        }
        isWorking = true
        isManualWarmupRunning = true
        status = .checking
        statusMessage = "세션 상태를 확인하고 있습니다."
        Task {
            defer {
                isManualWarmupRunning = false
                finishWorking()
            }
            do {
                let result = try await checkSession(
                    targetAt: event?.targetAt ?? now, event: event, context: "manual",
                    operationID: UUID().uuidString
                )
                connectionState = .connected
                if let event {
                    complete(event, quota: result.inspection.quota, status: result.status, message: result.message)
                } else {
                    record(result.status, message: result.message)
                    store.saveDailyCycle(cycle)
                }
            } catch {
                if error as? AppStateError == .scheduleChanged {
                    scheduleNext(reason: "operation_invalidated")
                } else if let event {
                    updateConnectionFailure(error)
                    handleTargetFailure(error, event: event)
                } else {
                    updateConnectionFailure(error)
                    record(.failed, message: "수동 워밍 실패: \(error.localizedDescription)")
                    store.saveDailyCycle(cycle)
                }
            }
        }
    }

    private func syncLaunchAtLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if settings.launchAtLogin != enabled {
            settings.launchAtLogin = enabled
            store.saveSettings(settings)
        }
    }

    private func scheduleNext(after date: Date? = nil, reason: String = "next_window") {
        guard !isWorking else {
            needsFreshSchedule = true
            pendingScheduleReasons.insert(reason)
            cancelScheduledTimer()
            return
        }
        let now = date ?? clock()
        cancelScheduledTimer()
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
        metadata["timer_id"] = nil // 새 예약의 식별자는 arm에서 발급한다.
        metadata["selected_at"] = diagnosticDate(now)
        metadata["source"] = event.windowNumber == 1 ? "first" : "reset_or_recovery"
        metadata["handled_windows"] = "\(cycle.handledWindows)"
        diagnosticLog("schedule.selected", metadata)
        arm(event, at: event.date, reason: reason)
    }

    /// 복귀 시 남은 시간을 다시 계산하되, 유효한 재시도 시각은 앞당기지 않는다.
    func reconcileSchedule(reason: String) {
        scheduleRevision += 1
        if ["system_wake", "startup", "login_completed"].contains(reason),
           cycle.firstFailure != nil, cycle.firstFailure?.retryAt == nil {
            cycle.firstFailure?.retryAt = clock()
            store.saveDailyCycle(cycle)
        }
        pendingScheduleReasons.insert(reason)
        cancelScheduledTimer()
        guard !isWorking else { return }
        reconcilePendingSchedule()
    }

    private func finishWorking() {
        isWorking = false
        if needsFreshSchedule || !pendingScheduleReasons.isEmpty {
            reconcilePendingSchedule()
        }
    }

    private func reconcilePendingSchedule() {
        let now = clock()
        let previous = nextEvent
        let reason = pendingScheduleReasons.sorted().joined(separator: ",")
        pendingScheduleReasons.removeAll()
        needsFreshSchedule = false
        scheduleNext(after: now, reason: reason)
        diagnosticLog("schedule.reconciled", [
            "reason": reason,
            "previous_target_at": diagnosticDate(previous?.targetAt),
            "previous_event_at": diagnosticDate(previous?.date),
            "next_target_at": diagnosticDate(nextEvent?.targetAt),
            "next_event_at": diagnosticDate(nextEvent?.date),
            "timer_id": scheduledTimerID?.uuidString ?? "none"
        ])
    }

    func arm(_ event: ScheduledEvent, at date: Date, reason: String = "scheduled") {
        cancelScheduledTimer()
        let id = UUID()
        scheduledTimerID = id
        let armedEvent = ScheduledEvent(
            date: date, targetAt: event.targetAt, dayKey: event.dayKey, windowNumber: event.windowNumber
        )
        nextEvent = armedEvent
        var metadata = scheduledMetadata(armedEvent)
        metadata["timer_id"] = id.uuidString
        metadata["clock"] = "wall"
        metadata["reason"] = reason
        metadata["armed_for"] = diagnosticDate(date)
        metadata["delay_ms"] = "\(Int(max(0, date.timeIntervalSince(clock())) * 1_000))"
        diagnosticLog("timer.armed", metadata)
        guard schedulerEnabled else { return }
        let armedMetadata = metadata
        timer = WallClockTimer(at: date) { [weak self] callbackAt in
            var callbackMetadata = armedMetadata
            callbackMetadata["callback_at"] = diagnosticDate(callbackAt)
            callbackMetadata["drift_ms"] = "\(Int(callbackAt.timeIntervalSince(date) * 1_000))"
            DiagnosticLogger.shared.log(event: "timer.callback", metadata: callbackMetadata, at: callbackAt)
            Task { @MainActor [weak self] in
                self?.receiveTimerCallback(armedEvent, id: id, callbackAt: callbackAt)
            }
        }
    }

    private func cancelScheduledTimer() {
        scheduledTimerID = nil
        timer?.cancel()
        timer = nil
    }

    func receiveTimerCallback(_ event: ScheduledEvent, id: UUID, callbackAt: Date) {
        let receivedAt = Date()
        var metadata = scheduledMetadata(event)
        metadata["timer_id"] = id.uuidString
        metadata["callback_at"] = diagnosticDate(callbackAt)
        metadata["fired_at"] = diagnosticDate(receivedAt)
        metadata["delivery_delay_ms"] = "\(Int(receivedAt.timeIntervalSince(callbackAt) * 1_000))"
        metadata["drift_ms"] = "\(Int(receivedAt.timeIntervalSince(event.date) * 1_000))"
        guard scheduledTimerID == id else {
            metadata["reason"] = "replaced_or_cancelled"
            diagnosticLog("timer.ignored", metadata)
            return
        }
        cancelScheduledTimer()
        metadata["was_working"] = isWorking ? "true" : "false"
        DiagnosticLogger.shared.logAndFlush(event: "timer.fired", metadata: metadata, at: receivedAt)
        DiagnosticContext.$scheduledTimerID.withValue(id.uuidString) {
            handle(event, timerID: id)
        }
    }

    func handle(_ event: ScheduledEvent, timerID: UUID? = nil) {
        guard !(cycle.dayKey == event.dayKey && cycle.handledWindows >= event.windowNumber) else { return }
        let now = clock()
        guard now >= event.date else {
            arm(event, at: event.date, reason: "early_callback")
            return
        }
        guard !isWorking else {
            arm(event, at: now.addingTimeInterval(5), reason: "working")
            return
        }
        guard eventIsCurrent(event, at: now) else {
            scheduleNext(reason: "event_changed")
            return
        }
        let candidate = engine.nextEvent(after: now, settings: settings, cycle: cycle)
        if let candidate, candidate.date > now {
            arm(candidate, at: candidate.date, reason: "retry_wait")
            return
        }

        performScheduledWarmup(for: event, timerID: timerID)
    }

    private func performScheduledWarmup(for event: ScheduledEvent, timerID: UUID?) {
        markScheduledWindowStarted(event)

        isWorking = true
        status = .checking
        statusMessage = "\(event.windowNumber)번째 창 확인 중"

        Task {
            defer { finishWorking() }
            await DiagnosticContext.$scheduledTimerID.withValue(timerID?.uuidString) {
                let quotaOperationID = UUID().uuidString
                do {
                    let result = try await checkSession(
                        targetAt: event.targetAt, event: event, context: "scheduled",
                        operationID: quotaOperationID
                    )
                    complete(event, quota: result.inspection.quota,
                             status: result.status,
                             message: result.message)
                } catch {
                    var failureMetadata = scheduledMetadata(event)
                    failureMetadata["operation_id"] = quotaOperationID
                    failureMetadata["error_code"] = diagnosticErrorCode(error)
                    diagnosticLog("window.attempt_failed", failureMetadata)
                    if error as? AppStateError == .scheduleChanged {
                        scheduleNext(reason: "operation_invalidated")
                    } else {
                        updateConnectionFailure(error)
                        handleTargetFailure(error, event: event)
                    }
                }
            }
        }
    }

    /// 수동·자동 워밍의 조회, 중복 방지, 호출, 활성화 확인을 동일하게 처리한다.
    private func checkSession(
        targetAt: Date, event: ScheduledEvent?, context: String, operationID: String
    ) async throws -> SessionCheckResult {
        var initial: Inspection
        var inspectedRevision: Int
        var inspectedAt: Date
        var refreshes = 0
        repeat {
            inspectedRevision = scheduleRevision
            inspectedAt = clock()
            initial = try await inspectClaude(operationID)
            refreshes += 1
        } while (inspectedRevision != scheduleRevision || clock().timeIntervalSince(inspectedAt) > 30) && refreshes < 2
        guard inspectedRevision == scheduleRevision, clock().timeIntervalSince(inspectedAt) <= 30 else {
            throw URLError(.timedOut)
        }
        if let event, !eventIsCurrent(event, at: clock()) { throw AppStateError.scheduleChanged }
        connectionState = .connected
        cacheQuota(initial.quota)
        logQuotaDecision(initial.quota, phase: "\(context)_pre", operationID: operationID, event: event)
        if sessionIsActive(initial.quota, event: event) {
            return SessionCheckResult(inspection: initial, performedWarmup: false)
        }
        guard !initial.quota.active else { throw AppStateError.quotaNotReset }

        let suppressed = shouldSuppressWarmup(for: targetAt, at: clock())
        var warmupError: Error?
        if !suppressed {
            cycle.lastWarmupTargetAt = targetAt
            cycle.lastWarmupAttemptAt = clock()
            record(.warming, message: "세션을 활성화하고 있습니다.")
            store.saveDailyCycle(cycle)
            let warmupOperationID = UUID().uuidString
            var metadata = event.map(scheduledMetadata) ?? [:]
            metadata["context"] = context
            metadata["operation_id"] = warmupOperationID
            diagnosticLog("warmup.requested", metadata)
            do {
                try await warmClaude(initial.cliURL, warmupOperationID)
            } catch {
                if error as? ClaudeServiceError == .warmupNotStarted {
                    cycle.lastWarmupTargetAt = nil
                    cycle.lastWarmupAttemptAt = nil
                    store.saveDailyCycle(cycle)
                    throw error
                }
                guard error as? ClaudeServiceError == .warmupTimedOut
                        || error as? ClaudeServiceError == .warmupFailed else { throw error }
                // 전송은 됐을 수 있으므로 응답 판정 실패도 새 호출 없이 확인한다.
                warmupError = error
            }
        }

        record(.checking, message: "세션 활성화를 확인하고 있습니다.")
        store.saveDailyCycle(cycle)
        var lastError = warmupError
        let confirmationDeadline = clock().addingTimeInterval(60)
        for seconds in [5, 10, 15, 15, 15] {
            if clock().addingTimeInterval(Double(seconds)) > confirmationDeadline { break }
            try await confirmationSleep(.seconds(seconds))
            if clock() > confirmationDeadline { break }
            let inspection: Inspection
            do {
                inspection = try await inspectClaude(operationID)
            } catch {
                guard Self.shouldRetryScheduledFailure(error) else { throw error }
                lastError = error
                continue
            }
            cacheQuota(inspection.quota)
            logQuotaDecision(inspection.quota, phase: "\(context)_post", operationID: operationID, event: event)
            if sessionIsActive(inspection.quota, event: event) {
                return SessionCheckResult(inspection: inspection, performedWarmup: !suppressed)
            }
        }
        throw lastError ?? AppStateError.recentWarmupUnconfirmed
    }

    private func sessionIsActive(_ quota: QuotaWindow, event: ScheduledEvent?) -> Bool {
        guard quota.active, let resetsAt = quota.resetsAt, resetsAt > clock() else { return false }
        cycle.lastWarmupTargetAt = nil
        cycle.lastWarmupAttemptAt = nil
        store.saveDailyCycle(cycle)
        return true
    }

    private func eventIsCurrent(_ event: ScheduledEvent, at now: Date) -> Bool {
        guard event.dayKey == engine.dayKey(for: now),
              let first = engine.firstWarmup(on: now, settings: settings), now >= first else { return false }
        let candidate = engine.nextEvent(after: now, settings: settings, cycle: cycle)
        return candidate?.targetAt == event.targetAt && candidate?.windowNumber == event.windowNumber
    }

    func markScheduledWindowStarted(_ event: ScheduledEvent) {
        if cycle.dayKey != event.dayKey {
            let pendingTarget = cycle.lastWarmupTargetAt
            let pendingAttempt = cycle.lastWarmupAttemptAt
            cycle = engine.newCycle(startingAt: event.targetAt)
            cycle.lastWarmupTargetAt = pendingTarget
            cycle.lastWarmupAttemptAt = pendingAttempt
        }
        if cycle.firstFailure?.targetAt != event.targetAt { cycle.firstFailure = nil }
        cycle.nextResetAt = event.targetAt
        record(.checking, message: "\(event.windowNumber)번째 창 확인 시작")
        store.saveDailyCycle(cycle)
    }

    private func complete(
        _ event: ScheduledEvent,
        quota: QuotaWindow,
        status completedStatus: WarmupStatus,
        message: String
    ) {
        cacheQuota(quota)
        cycle.firstFailure = nil
        // 서버 시각의 1분 이내 보정은 같은 창으로 취급한다.
        let alreadyCounted = cycle.lastConfirmedResetAt.map {
            abs($0.timeIntervalSince(quota.resetsAt!)) <= 60
        } ?? false
        if !alreadyCounted {
            cycle.handledWindows = min(cycle.handledWindows + 1, ScheduleEngine.maximumWindowsPerDay)
        }
        cycle.lastConfirmedResetAt = quota.resetsAt
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
        scheduleNext(after: clock().addingTimeInterval(0.1))
    }

    static func shouldRetryScheduledFailure(_ error: Error) -> Bool {
        if let serviceError = error as? ClaudeServiceError {
            switch serviceError {
            case .oauthRefreshUnavailable, .quotaRateLimited, .quotaUnavailable:
                return true
            case .warmupNotStarted, .warmupTimedOut, .warmupFailed:
                // 이미 전송됐을 수 있다. 기존 중복 방지에 따라 후속 시도는 사용량만 확인한다.
                return true
            default: return false
            }
        }
        return error is AppStateError || error is URLError
    }

    func handleTargetFailure(_ error: Error, event: ScheduledEvent, at date: Date? = nil) {
        let now = date ?? clock()
        guard !(cycle.dayKey == event.dayKey && cycle.handledWindows >= event.windowNumber) else { return }
        if cycle.firstFailure?.targetAt != event.targetAt {
            cycle.firstFailure = ScheduledWindowFailure(
                targetAt: event.targetAt, message: "워밍 확인 실패: \(error.localizedDescription)"
            )
        }
        let attempts = (cycle.firstFailure?.attempts ?? 0) + 1
        cycle.firstFailure?.attempts = attempts
        let retryAt = now.addingTimeInterval(30)
        let canRetry = Self.shouldRetryScheduledFailure(error) && attempts <= 3
        cycle.firstFailure?.retryAt = canRetry ? retryAt : nil
        record(canRetry ? .checking : .failed, message: canRetry
            ? "30초 후 세션 상태를 다시 확인합니다."
            : hasUnconfirmedWarmup
                ? "전송 결과 미확인: 다시 전송하지 않습니다. 상태 확인 또는 재전송을 선택해 주세요."
                : "\(cycle.firstFailure!.message) · 복귀 또는 지금 워밍으로 재시도할 수 있습니다.")
        store.saveDailyCycle(cycle)
        var metadata = scheduledMetadata(event)
        metadata["attempts"] = "\(attempts)"
        metadata["retry_at"] = diagnosticDate(cycle.firstFailure?.retryAt)
        metadata["error_code"] = diagnosticErrorCode(error)
        metadata["handled_windows"] = "\(cycle.handledWindows)"
        diagnosticLogCritical(canRetry ? "window.retry_armed" : "window.recovery_wait", metadata)
        if canRetry {
            let retry = ScheduledEvent(date: retryAt, targetAt: event.targetAt,
                                       dayKey: event.dayKey, windowNumber: event.windowNumber)
            nextEvent = retry
            arm(retry, at: retryAt, reason: "retry")
        } else {
            if schedulerEnabled { notifyFailure(statusMessage) }
            scheduleNext(after: now, reason: "recovery_wait")
        }
    }

    func shouldSuppressWarmup(for targetAt: Date, at now: Date) -> Bool {
        // 미확인 전송은 시간 경과·날짜 변경·재시작으로 해제하지 않는다.
        hasUnconfirmedWarmup
    }

    private func scheduledMetadata(_ event: ScheduledEvent) -> [String: String] {
        var metadata = [
            "day_key": event.dayKey,
            "window": "\(event.windowNumber)",
            "target_at": diagnosticDate(event.targetAt),
            "event_at": diagnosticDate(event.date)
        ]
        metadata["timer_id"] = DiagnosticContext.scheduledTimerID
        return metadata
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
        case .scheduleChanged: return "schedule_changed"
        }
    }

    private func record(_ newStatus: WarmupStatus, message: String) {
        status = newStatus
        statusMessage = message
        cycle.lastRecord = WarmupRecord(timestamp: clock(), status: newStatus, message: message)
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
        } else if serviceError == .oauthRefreshUnavailable
                    || serviceError == .quotaRateLimited
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

private struct SessionCheckResult {
    let inspection: Inspection
    let performedWarmup: Bool

    var status: WarmupStatus { performedWarmup ? .succeeded : .satisfied }

    var message: String {
        performedWarmup ? "세션 활성화를 확인했습니다." : "이미 세션이 활성화되었습니다."
    }
}

struct Inspection: Sendable {
    let cliURL: URL
    let quota: QuotaWindow
    let operationID: String
}

private enum AppStateError: LocalizedError {
    case scheduleChanged
    case quotaNotReset
    case quotaNotActivated
    case recentWarmupUnconfirmed

    var errorDescription: String? {
        switch self {
        case .scheduleChanged:
            return "일정이 변경되어 현재 조건으로 다시 확인합니다."
        case .quotaNotReset:
            return "이전 사용량 창이 아직 종료되지 않았습니다."
        case .quotaNotActivated:
            return "워밍 후 새 사용량 창을 확인하지 못했습니다."
        case .recentWarmupUnconfirmed:
            return "최근 워밍 결과가 아직 확인되지 않아 다시 호출하지 않습니다."
        }
    }
}
