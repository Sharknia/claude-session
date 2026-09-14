import AppKit
import Combine
import Foundation

/// 실제 예약 코드와 OS 잠자기를 검증한다. 설정은 격리하고 Claude·Keychain에는 접근하지 않는다.
@main
struct VerifyScheduler {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, ["awake", "before", "multiple", "after"].contains(args[0]),
              let seconds = Double(args[1]), seconds.isFinite, (5...3600).contains(seconds) else {
            print("사용법: verify-scheduler.sh <awake|before|multiple|after> <5~3600초>")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let probe = SchedulerSleepProbe(mode: args[0], delay: seconds)
        withExtendedLifetime(probe) { app.run() }
    }
}

@MainActor
private final class SchedulerSleepProbe {
    private let mode: String
    private let target: Date
    private let suite = "ClaudeSessionWarmer.SleepProbe.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let state: AppState
    private let backend: ProbeBackend
    private var observations: Set<AnyCancellable> = []
    private var powerObservers: [NSObjectProtocol] = []
    private var sleeps: [Date] = []
    private var wakes: [Date] = []
    private var timeout: WallClockTimer?
    private var finished = false

    init(mode: String, delay: TimeInterval) {
        self.mode = mode
        target = Date().addingTimeInterval(delay)
        defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        let engine = ScheduleEngine()
        store.saveSettings(ScheduleSettings(firstWarmupMinutes: 0, weekdays: Set(1...7), excludeKoreanHolidays: false))
        store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: target), handledWindows: 1, nextResetAt: target))
        backend = ProbeBackend(reset: target.addingTimeInterval(18_000))
        let backend = backend
        state = AppState(store: store, engine: engine,
                         inspectClaude: { await backend.inspect($0) },
                         warmClaude: { _, _ in fatalError("검증 프로그램에서 실제 워밍 금지") },
                         confirmationSleep: { _ in })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                let observedAt = Date()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification { self.sleeps.append(observedAt) }
                    else { self.wakes.append(observedAt) }
                    print("power=\(name.rawValue) at=\(diagnosticDate(observedAt))")
                    fflush(nil)
                }
            })
        }
        state.$cycle.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }.store(in: &observations)
        state.$isWorking.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }.store(in: &observations)
        timeout = WallClockTimer(at: target.addingTimeInterval(600)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(passed: false, details: "timeout=true") }
        }
        print("mode=\(mode) pid=\(ProcessInfo.processInfo.processIdentifier) target_at=\(diagnosticDate(target))")
        print("log_directory=\(FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeSessionWarmerTests-\(ProcessInfo.processInfo.processIdentifier)").path)")
        print("실제 잠자기 조작은 자동 수행하지 않습니다. before/multiple은 목표 전에, after는 목표 5초 이후 복귀하세요.")
        fflush(nil)
    }

    private func evaluate() {
        guard !finished, !state.isWorking, state.cycle.handledWindows >= 2 else { return }
        finished = true
        Task {
            let (count, inspectedAt) = await backend.result()
            let beforeSleeps = sleeps.filter { $0 < target }.count
            let beforeWakes = wakes.filter { $0 < target }.count
            let drift = inspectedAt?.timeIntervalSince(target)
            let timingOK = drift.map { (0...5).contains($0) } == true
            let passed: Bool
            if mode == "after" {
                passed = beforeSleeps > 0 && count == 0 && state.status == .missed
                    && Date() > target.addingTimeInterval(5)
            } else {
                let requiredSleeps = mode == "awake" ? 0 : mode == "multiple" ? 2 : 1
                passed = beforeSleeps >= requiredSleeps && beforeWakes >= requiredSleeps
                    && timingOK && count == 1 && state.status == .satisfied
            }
            finish(passed: passed, details: "inspections=\(count) sleeps=\(beforeSleeps) wakes=\(wakes.count) drift_s=\(drift.map(String.init(describing:)) ?? "none") status=\(state.status)")
        }
    }

    private func finish(passed: Bool, details: String) {
        print("result=\(passed ? "passed" : "failed") \(details)")
        DiagnosticLogger.shared.flush()
        defaults.removePersistentDomain(forName: suite)
        powerObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        exit(passed ? 0 : 1)
    }
}

private actor ProbeBackend {
    private let reset: Date
    private var count = 0
    private var inspectedAt: Date?
    init(reset: Date) { self.reset = reset }
    func inspect(_ id: String) -> Inspection {
        count += 1
        inspectedAt = Date()
        return Inspection(cliURL: URL(fileURLWithPath: "/unused-sleep-probe"),
                          quota: QuotaWindow(active: true, resetsAt: reset), operationID: id)
    }
    func result() -> (Int, Date?) { (count, inspectedAt) }
}
