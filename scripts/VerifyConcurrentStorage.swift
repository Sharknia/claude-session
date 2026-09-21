import AppKit
import Foundation

/// 실제 프로세스·잠금·AppState·파일 저장을 함께 실행한다. Claude와 운영 설정은 사용하지 않는다.
@MainActor
enum ConcurrentStorageProbe {
    static func run(_ args: [String]) {
        guard args.count == 2, ["seed", "worker", "pause"].contains(args[0]),
              args[1].contains("/ClaudeSessionWarmerTests-") else { exit(2) }
        let root = URL(fileURLWithPath: args[1])
        let now = ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let engine = ScheduleEngine(calendar: calendar)
        do {
            let defaults = MemoryDefaults()
            if args[0] == "seed" {
                let owner = try ExecutionOwnership(directory: root)
                let store = SettingsStore(defaults: defaults, directory: root)
                guard store.saveSettings(ScheduleSettings(firstWarmupMinutes: 0, weekdays: Set(1...7), excludeKoreanHolidays: false)),
                      store.saveDailyCycle(DailyCycle(dayKey: engine.dayKey(for: now))),
                      let settings = defaults.data(forKey: SettingsStore.settingsKey) else { exit(3) }
                try AtomicStateFile.write(settings, to: root.appendingPathComponent("settings-fixture.json"))
                withExtendedLifetime(owner) {}
                return
            }
            print("ready")
            fflush(nil)
            guard readLine() == "start" else { exit(4) }
            let owner: ExecutionOwnership
            do { owner = try ExecutionOwnership(directory: root) }
            catch ExecutionOwnership.Failure.alreadyRunning { print("blocked"); exit(2) }
            print("owner")
            fflush(nil)
            defaults.set(try Data(contentsOf: root.appendingPathComponent("settings-fixture.json")),
                         forKey: SettingsStore.settingsKey)
            let store = SettingsStore(defaults: defaults, directory: root)
            guard store.issue == nil else { print("storage_blocked"); exit(5) }
            let backend = ConcurrentBackend(root: root, reset: now.addingTimeInterval(18_000), pause: args[0] == "pause")
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let state = AppState(store: store, engine: engine, startScheduler: false, clock: { now },
                                 inspectClaude: { try await backend.inspect($0) },
                                 warmClaude: { _, _ in try await backend.warm() }, confirmationSleep: { _ in })
            state.handle(ScheduledEvent(date: now, targetAt: now, dayKey: engine.dayKey(for: now), windowNumber: 1))
            Task {
                for _ in 0..<500 {
                    if !state.isWorking { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard !state.isWorking else { exit(6) }
                // 동시에 시작한 두 번째 프로세스가 소유권 판정을 끝낼 때까지 유지한다.
                try? await Task.sleep(for: .milliseconds(500))
                let result: [String: Any] = ["status": state.status.rawValue, "handled": state.cycle.handledWindows,
                                             "pending": state.hasUnconfirmedWarmup, "requests": await backend.requests()]
                let data = try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                print(String(decoding: data, as: UTF8.self))
                DiagnosticLogger.shared.flush()
                exit(0)
            }
            withExtendedLifetime((owner, state)) { app.run() }
        } catch { print("probe_error=\(error)"); exit(7) }
    }
}

private actor ConcurrentBackend {
    let root: URL
    let reset: Date
    let pause: Bool

    init(root: URL, reset: Date, pause: Bool) { self.root = root; self.reset = reset; self.pause = pause }

    func requests() -> Int {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fake-requests.json")),
              let count = try? JSONDecoder().decode(Int.self, from: data) else { return 0 }
        return count
    }

    func inspect(_ id: String) throws -> Inspection {
        let active = requests() > 0
        return Inspection(cliURL: URL(fileURLWithPath: "/unused-fake-cli"),
                          quota: QuotaWindow(active: active, resetsAt: active ? reset : nil), operationID: id)
    }

    func warm() throws {
        let saved = try JSONDecoder().decode(StoredRecord<DailyCycle>.self,
            from: Data(contentsOf: root.appendingPathComponent(SettingsStore.runtimeFile)))
        guard saved.value.lastWarmupTargetAt != nil, saved.value.lastWarmupAttemptAt != nil else {
            throw StoredValueError.invalid("전송 전에 디스크에 표식이 없습니다.")
        }
        if pause {
            print("before_send")
            fflush(nil)
            _ = readLine()
        }
        try AtomicStateFile.write(JSONEncoder().encode(requests() + 1), to: root.appendingPathComponent("fake-requests.json"))
    }
}
