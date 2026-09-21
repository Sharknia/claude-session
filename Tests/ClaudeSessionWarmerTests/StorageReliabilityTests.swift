import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class StorageReliabilityTests: XCTestCase {
    func testInvalidLegacyRecordsArePreservedWithoutMigration() throws {
        let cases: [(String, String)] = [
            ("scheduleSettings", #"{"firstWarmupMinutes":-15,"weekdays":[0,8],"excludeKoreanHolidays":true,"launchAtLogin":false}"#),
            ("dailyCycle", #"{"handledWindows":-2}"#),
            ("dailyCycle", #"{"handledWindows":4}"#),
            ("dailyCycle", #"{"handledWindows":1}"#),
            ("dailyCycle", #"{"handledWindows":1,"dayKey":"2026-02-30"}"#),
            ("dailyCycle", #"{"handledWindows":0,"lastWarmupAttemptAt":100}"#),
            ("dailyCycle", #"{"handledWindows":0,"firstFailure":{"targetAt":100,"message":"x","attempts":-1}}"#),
            ("dailyCycle", #"{"handledWindows":0,"firstFailure":{"targetAt":100,"message":"x","retryAt":99}}"#),
            ("dailyCycle", "{\"handledWindows\":")
        ]
        for (key, text) in cases {
            let defaults = MemoryDefaults()
            defaults.set(Data(text.utf8), forKey: key)
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let store = SettingsStore(defaults: defaults)
            XCTAssertEqual(store.issue?.kind, .corrupt, text)
            XCTAssertFalse(store.saveDailyCycle(DailyCycle()), text)
            XCTAssertEqual(before, defaults.dictionaryRepresentation() as NSDictionary, text)
        }
    }

    @MainActor
    func testUnsupportedSchemaCannotInspectSendOrWrite() async throws {
        for key in [SettingsStore.settingsKey, "isolated.\(SettingsStore.runtimeFile)"] {
            let defaults = MemoryDefaults()
            defaults.set(Data(#"{"schemaVersion":2,"minimumReaderVersion":2,"value":{"future":"keep"}}"#.utf8), forKey: key)
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let store = SettingsStore(defaults: defaults)
            let state = AppState(store: store, startScheduler: true,
                                 inspectClaude: { _ in XCTFail("미래 형식에서 조회"); throw URLError(.cancelled) },
                                 warmClaude: { _, _ in XCTFail("미래 형식에서 전송") })
            state.manualWarmup(allowResend: true)
            state.refreshSilently(force: true)
            state.connectClaude()
            await Task.yield()
            XCTAssertEqual(store.issue?.kind, .unsupported)
            XCTAssertNotNil(state.operationBlockReason)
            XCTAssertNil(state.nextEvent)
            XCTAssertEqual(before, defaults.dictionaryRepresentation() as NSDictionary)
        }
    }

    func testLegacyWritesCannotOverwriteMigratedRecord() throws {
        let defaults = MemoryDefaults()
        let pending = DailyCycle(dayKey: "2026-09-21", handledWindows: 2,
                                 lastWarmupTargetAt: Date(timeIntervalSince1970: 100),
                                 lastWarmupAttemptAt: Date(timeIntervalSince1970: 101))
        let original = try JSONEncoder().encode(pending)
        defaults.set(original, forKey: "dailyCycle")
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.issue)
        XCTAssertEqual(store.disposition, .migrationNeeded)
        XCTAssertEqual(defaults.data(forKey: "dailyCycle"), original)
        defaults.set(try JSONEncoder().encode(DailyCycle()), forKey: "dailyCycle")
        let restarted = SettingsStore(defaults: defaults)
        XCTAssertNil(restarted.issue)
        XCTAssertEqual(restarted.loadDailyCycle(), pending)
        restarted.clearQuotaCache()
        XCTAssertEqual(restarted.loadDailyCycle(), pending)
    }

    func testMissingModernRecordNeverReimportsLegacy() throws {
        let defaults = MemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.saveDailyCycle(DailyCycle(dayKey: "2026-09-21", handledWindows: 2)))
        defaults.removeObject(forKey: "isolated.\(SettingsStore.runtimeFile)")
        defaults.set(try JSONEncoder().encode(DailyCycle()), forKey: "dailyCycle")
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let restarted = SettingsStore(defaults: defaults)
        XCTAssertEqual(restarted.issue?.area, .runtime)
        XCTAssertEqual(before, defaults.dictionaryRepresentation() as NSDictionary)
    }

    func testMigrationResumesAtEveryFileWriteBoundary() throws {
        for interruptedWrite in 1...3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = MemoryDefaults()
            let pending = DailyCycle(dayKey: "2026-09-21", handledWindows: 2,
                                     lastWarmupTargetAt: Date(timeIntervalSince1970: 100))
            let original = try JSONEncoder().encode(pending)
            defaults.set(original, forKey: "dailyCycle")
            var writes = 0
            let interrupted = SettingsStore(defaults: defaults, directory: root) { data, url in
                writes += 1
                if writes == interruptedWrite { throw CocoaError(.fileWriteOutOfSpace) }
                try AtomicStateFile.write(data, to: url)
            }
            XCTAssertNotNil(interrupted.issue)
            if interruptedWrite > 1 {
                // 이전 도중 구버전이 예전 키를 다시 써도 최초 보존본에서 이어져야 한다.
                defaults.set(try JSONEncoder().encode(DailyCycle()), forKey: "dailyCycle")
            }
            let legacyAfterInterruption = defaults.data(forKey: "dailyCycle")
            let resumed = SettingsStore(defaults: defaults, directory: root)
            XCTAssertNil(resumed.issue)
            XCTAssertEqual(resumed.loadDailyCycle(), pending)
            XCTAssertEqual(defaults.data(forKey: "dailyCycle"), legacyAfterInterruption)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])
        }
    }

    @MainActor
    func testDiskFailureBeforeSendPreventsWarmup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = WriteFault()
        let store = SettingsStore(defaults: MemoryDefaults(), directory: root) { data, url in
            if fault.fail { throw CocoaError(.fileWriteOutOfSpace) }
            try AtomicStateFile.write(data, to: url)
        }
        let now = Date()
        XCTAssertTrue(store.saveDailyCycle(DailyCycle(dayKey: ScheduleEngine().dayKey(for: now), handledWindows: 3)))
        let original = try Data(contentsOf: root.appendingPathComponent(SettingsStore.runtimeFile))
        let state = AppState(store: store, startScheduler: false,
                             inspectClaude: { id in Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                                                              quota: QuotaWindow(active: false), operationID: id) },
                             warmClaude: { _, _ in XCTFail("영속 저장 실패 뒤 전송") })
        fault.fail = true
        state.manualWarmup()
        try await waitUntilFinished(state)
        XCTAssertEqual(state.status, .failed)
        XCTAssertNotNil(state.operationBlockReason)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SettingsStore.runtimeFile)), original)
    }

    @MainActor
    func testWriteFailureAfterSendRetainsPendingMarkerAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let fault = WriteFault()
        let store = SettingsStore(defaults: defaults, directory: root) { data, url in
            if fault.fail { throw CocoaError(.fileWriteOutOfSpace) }
            try AtomicStateFile.write(data, to: url)
        }
        XCTAssertTrue(store.saveDailyCycle(DailyCycle(dayKey: ScheduleEngine().dayKey(for: Date()), handledWindows: 3)))
        let state = AppState(store: store, startScheduler: false,
                             inspectClaude: { id in Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                                                              quota: QuotaWindow(active: false), operationID: id) },
                             warmClaude: { _, _ in await MainActor.run { fault.fail = true } })
        state.manualWarmup()
        try await waitUntilFinished(state)
        XCTAssertEqual(state.status, .failed)
        XCTAssertNotNil(state.operationBlockReason)
        let restarted = SettingsStore(defaults: defaults, directory: root)
        XCTAssertNil(restarted.issue)
        XCTAssertNotNil(restarted.loadDailyCycle().lastWarmupAttemptAt)
        XCTAssertEqual(restarted.loadDailyCycle().handledWindows, 3)
    }

    func testAtomicReplacementFailurePreservesDestinationAndRemovesTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AtomicStateFile.write(Data("new".utf8), to: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["state"])
    }

    func testReadOnlyDirectoryDoesNotLoseExistingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("state.json")
        let original = Data("original".utf8)
        try AtomicStateFile.write(original, to: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try AtomicStateFile.write(Data("replacement".utf8), to: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testRepairingLegacySettingsPreservesCountAndOriginal() throws {
        let defaults = MemoryDefaults()
        let broken = Data("{broken settings".utf8)
        defaults.set(broken, forKey: "scheduleSettings")
        let pending = DailyCycle(dayKey: "2026-09-21", handledWindows: 2, lastWarmupTargetAt: Date())
        defaults.set(try JSONEncoder().encode(pending), forKey: "dailyCycle")
        let store = SettingsStore(defaults: defaults)
        let state = AppState(store: store, startScheduler: false)
        XCTAssertNotNil(state.operationBlockReason)
        XCTAssertTrue(state.canEditSettings)
        XCTAssertTrue(state.applySettings(firstWarmupDate: Date(), weekdays: [2, 3], excludeKoreanHolidays: false))
        XCTAssertNil(store.issue)
        XCTAssertNil(state.operationBlockReason)
        XCTAssertEqual(state.cycle, pending)
        XCTAssertEqual(defaults.data(forKey: "scheduleSettings"), broken)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.contains { $0.contains("settings-damaged-") })
    }

    @MainActor
    func testBackupRecoveryPreservesOriginalAndNeverResendsAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let store = SettingsStore(defaults: defaults, directory: root)
        let now = ISO8601DateFormatter().date(from: "2026-09-21T05:00:00Z")!
        XCTAssertTrue(store.saveSettings(ScheduleSettings(weekdays: Set(1...7), excludeKoreanHolidays: false)))
        XCTAssertTrue(store.saveDailyCycle(DailyCycle(dayKey: "2026-09-21", handledWindows: 1)))
        XCTAssertTrue(store.saveDailyCycle(DailyCycle(dayKey: "2026-09-21", handledWindows: 2)))
        let backup = try Data(contentsOf: root.appendingPathComponent(SettingsStore.backupFile))
        let damaged = Data("{cut transmission record".utf8)
        try damaged.write(to: root.appendingPathComponent(SettingsStore.runtimeFile))
        let reloaded = SettingsStore(defaults: defaults, directory: root)
        let state = AppState(store: reloaded, startScheduler: false, clock: { now },
                             inspectClaude: { id in Inspection(cliURL: URL(fileURLWithPath: "/unused"),
                                                              quota: QuotaWindow(active: false), operationID: id) },
                             warmClaude: { _, _ in XCTFail("백업 복구 뒤 불확실한 전송을 반복함") },
                             confirmationSleep: { _ in })
        XCTAssertTrue(state.canRecoverRuntime)
        state.recoverRuntime()
        XCTAssertNil(reloaded.issue)
        XCTAssertEqual(state.cycle.handledWindows, 1) // 백업의 값만 보존; 성공 횟수를 만들어내지 않는다.
        XCTAssertEqual(state.cycle.recoveryHoldDayKey, "2026-09-21")
        XCTAssertTrue(state.hasUnconfirmedWarmup)
        XCTAssertFalse(state.hasReadableCycle) // 당일 횟수는 확정할 수 없다.
        XCTAssertNotEqual(state.nextEvent?.dayKey, "2026-09-21")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SettingsStore.backupFile)), backup)
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("runtime-damaged-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), damaged)
        state.manualWarmup()
        try await waitUntilFinished(state)
        XCTAssertTrue(state.hasUnconfirmedWarmup)
        let restarted = SettingsStore(defaults: defaults, directory: root)
        XCTAssertNotNil(restarted.loadDailyCycle().lastWarmupTargetAt)
        XCTAssertEqual(restarted.loadDailyCycle().recoveryHoldDayKey, "2026-09-21")
    }

    func testRecoveryRejectsFutureBackupWithoutChangingCurrentFile() throws {
        let defaults = MemoryDefaults()
        _ = SettingsStore(defaults: defaults)
        defaults.set(Data("broken".utf8), forKey: "isolated.\(SettingsStore.runtimeFile)")
        defaults.set(Data(#"{"schemaVersion":9,"minimumReaderVersion":9,"value":{}}"#.utf8),
                     forKey: "isolated.\(SettingsStore.backupFile)")
        let store = SettingsStore(defaults: defaults)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        XCTAssertFalse(store.recoverRuntime(at: Date(), dayKey: "2026-09-21"))
        XCTAssertEqual(store.issue?.kind, .unsupported)
        XCTAssertEqual(before, defaults.dictionaryRepresentation() as NSDictionary)
    }

    @MainActor
    func testFutureFileAppearingWhileRunningBlocksAuthentication() async {
        let defaults = MemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        let state = AppState(store: store, startScheduler: false,
                             inspectClaude: { _ in XCTFail("미래 형식 교체 뒤 인증 조회"); throw URLError(.cancelled) })
        defaults.set(Data(#"{"schemaVersion":2,"minimumReaderVersion":2,"value":{}}"#.utf8),
                     forKey: "isolated.\(SettingsStore.runtimeFile)")
        let before = defaults.dictionaryRepresentation() as NSDictionary
        state.refreshSilently(force: true)
        await Task.yield()
        XCTAssertEqual(state.storageIssue?.kind, .unsupported)
        XCTAssertEqual(before, defaults.dictionaryRepresentation() as NSDictionary)
    }

    @MainActor
    func testMaximumRetryCounterDoesNotOverflow() throws {
        let defaults = MemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        let now = Date()
        let key = ScheduleEngine().dayKey(for: now)
        XCTAssertTrue(store.saveDailyCycle(DailyCycle(dayKey: key,
            firstFailure: ScheduledWindowFailure(targetAt: now, message: "failed", attempts: Int.max))))
        let state = AppState(store: store, startScheduler: false, clock: { now })
        state.handleTargetFailure(URLError(.notConnectedToInternet),
                                  event: ScheduledEvent(date: now, targetAt: now, dayKey: key, windowNumber: 1))
        XCTAssertEqual(state.cycle.firstFailure?.attempts, Int.max)
        XCTAssertNil(state.operationBlockReason)
    }

    @MainActor
    func testModernPendingRecordDoesNotUseLegacySuccessCleanup() {
        let store = SettingsStore(defaults: MemoryDefaults())
        let now = Date()
        let pending = DailyCycle(lastWarmupTargetAt: now,
                                 lastRecord: WarmupRecord(timestamp: now.addingTimeInterval(-10),
                                                          status: .succeeded, message: "이전 성공"))
        XCTAssertTrue(store.saveDailyCycle(pending))
        let state = AppState(store: store, startScheduler: false)
        XCTAssertTrue(state.hasUnconfirmedWarmup)
        XCTAssertEqual(state.cycle, pending)
    }

    func testCorruptMigrationMetadataRecoveryKeepsCurrentRecords() throws {
        let defaults = MemoryDefaults()
        let original = SettingsStore(defaults: defaults)
        let cycle = DailyCycle(dayKey: "2026-09-21", handledWindows: 2, lastWarmupTargetAt: Date())
        XCTAssertTrue(original.saveDailyCycle(cycle))
        let settingsData = defaults.data(forKey: SettingsStore.settingsKey)
        let runtimeData = defaults.data(forKey: "isolated.\(SettingsStore.runtimeFile)")
        let damaged = Data("broken migration metadata".utf8)
        defaults.set(damaged, forKey: "isolated.\(SettingsStore.migrationFile)")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.issue?.area, .migration)
        XCTAssertTrue(store.canRecoverRuntime)
        XCTAssertTrue(store.recoverRuntime(at: Date(), dayKey: "2026-09-21"))
        XCTAssertNil(store.issue)
        XCTAssertEqual(store.loadDailyCycle(), cycle)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.settingsKey), settingsData)
        XCTAssertEqual(defaults.data(forKey: "isolated.\(SettingsStore.runtimeFile)"), runtimeData)
        let originals = defaults.dictionaryRepresentation().filter { $0.key.contains("migration-damaged-") }
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(originals.values.first as? Data, damaged)
    }

    @MainActor
    private func waitUntilFinished(_ state: AppState) async throws {
        for _ in 0..<100 {
            if !state.isWorking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("작업 종료 시간 초과")
    }
}

@MainActor
private final class WriteFault {
    var fail = false
}
