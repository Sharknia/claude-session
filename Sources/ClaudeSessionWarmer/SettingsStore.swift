import Foundation

struct StoredRecord<Value: Codable>: Codable {
    var schemaVersion = 1
    var minimumReaderVersion = 1
    var value: Value
}

struct StorageIssue: Error, Equatable {
    enum Area: String { case settings, runtime, migration }
    enum Kind: Equatable { case corrupt, unsupported, unavailable }
    let area: Area
    let kind: Kind
    let detail: String

    var message: String {
        if kind == .unsupported { return "더 새로운 앱에서 저장한 데이터입니다. 앱을 업데이트해 주세요. 기록은 변경하지 않았습니다." }
        let name = area == .settings ? "예약 설정" : area == .runtime ? "실행 기록" : "데이터 이전 기록"
        return "\(name)을 읽거나 저장하지 못해 실행을 중지했습니다. \(detail)"
    }
}

/// 제품에서는 사용자별 파일을 사용한다. 명시적으로 주입한 defaults만 있으면 시험용 메모리 경로를 사용한다.
final class SettingsStore {
    static let settingsKey = "scheduleSettings.versioned"
    static let runtimeFile = "runtime-state.json"
    static let backupFile = "runtime-state.backup.json"
    static let migrationFile = "migration.json"

    enum LoadDisposition { case missing, valid, migrationNeeded, corrupt, unsupported }
    private(set) var disposition: LoadDisposition = .missing
    private(set) var issue: StorageIssue?
    private(set) var settings = ScheduleSettings()
    private(set) var cycle = DailyCycle()
    private(set) var hasReadableCycle = false
    private(set) var hasReadableSettings = false
    let directory: URL?
    private let defaults: UserDefaults
    private let fileWriter: (Data, URL) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct Header: Decodable { let schemaVersion: Int; let minimumReaderVersion: Int }
    private struct Migration: Codable {
        var completed: Bool
        let settings: ScheduleSettings
        let cycle: DailyCycle
        let originalSettings: Data?
        let originalCycle: Data?
    }

    convenience init() {
        self.init(defaults: .standard, directory: InstallationPolicy.dataDirectory)
    }

    init(defaults: UserDefaults, directory: URL? = nil,
         fileWriter: @escaping (Data, URL) throws -> Void = AtomicStateFile.write) {
        self.defaults = defaults
        self.directory = directory
        self.fileWriter = fileWriter
        prepare()
    }

    // 손상 시 반환값은 편집·표시용 초안이다. issue가 해소되기 전에는 저장·실행하지 않는다.
    func loadSettings() -> ScheduleSettings { hasReadableSettings ? settings : ScheduleSettings() }
    func loadDailyCycle() -> DailyCycle { hasReadableCycle ? cycle : DailyCycle() }

    var canRepairSettings: Bool { issue?.area == .settings && issue?.kind == .corrupt }
    var canRecoverRuntime: Bool {
        issue?.kind == .corrupt && hasReadableSettings
            && (issue?.area == .runtime || (issue?.area == .migration && hasReadableCycle))
    }

    @discardableResult
    func reload() -> Bool {
        prepare()
        return issue == nil
    }

    /// 사용자가 고친 예약 초안만 적용한다. 손상 원본은 별도 보존한다.
    @discardableResult
    func repairSettings(_ value: ScheduleSettings) -> Bool {
        prepare()
        if issue == nil { return saveSettings(value) }
        guard canRepairSettings else { return false }
        do {
            try value.validate()
            try preservePreferences(named: "settings-damaged")
            if let data = try readFile(Self.migrationFile) {
                let previous = try decodeRecord(Migration.self, data, area: .migration)
                if !previous.completed {
                    let updated = Migration(completed: false, settings: value, cycle: previous.cycle,
                                            originalSettings: previous.originalSettings, originalCycle: previous.originalCycle)
                    try writeRecord(updated, file: Self.migrationFile)
                }
            } else if try readFile(Self.runtimeFile) == nil, hasReadableCycle {
                let migration = Migration(completed: false, settings: value, cycle: cycle,
                                          originalSettings: defaults.object(forKey: "scheduleSettings") as? Data,
                                          originalCycle: defaults.object(forKey: "dailyCycle") as? Data)
                try writeRecord(migration, file: Self.migrationFile)
            }
            defaults.set(try encoder.encode(StoredRecord(value: value)), forKey: Self.settingsKey)
            prepare()
            return issue == nil
        } catch { setIssue(problem(error, area: .settings)); return false }
    }

    /// 백업에는 마지막 전송이 없을 수 있다. 당일 자동 실행을 끝내고 미확인 표식을 반드시 남긴다.
    @discardableResult
    func recoverRuntime(at now: Date, dayKey: String) -> Bool {
        prepare()
        if issue == nil { return true }
        guard canRecoverRuntime else { return false }
        do {
            if issue?.area == .migration {
                // 이전 메타데이터만 손상된 경우 검증된 현재 실행 기록까지 되돌리지 않는다.
                if let damaged = try readFile(Self.migrationFile) {
                    try writeFile(damaged, name: "migration-damaged-\(UUID().uuidString).json")
                }
                try writeRecord(Migration(completed: true, settings: settings, cycle: cycle,
                                          originalSettings: nil, originalCycle: nil), file: Self.migrationFile)
                prepare()
                return issue == nil
            }
            var recovered = DailyCycle()
            if let backup = try readFile(Self.backupFile) {
                do {
                    recovered = try decodeRecord(DailyCycle.self, backup, area: .runtime)
                    try recovered.validate()
                } catch {
                    if let failure = error as? StorageIssue, failure.kind == .unsupported { throw failure }
                    recovered = DailyCycle()
                }
            }
            if let damaged = try readFile(Self.runtimeFile) {
                try writeFile(damaged, name: "runtime-damaged-\(UUID().uuidString).json")
            }
            try preservePreferences(named: "runtime-legacy-original")
            recovered.dayKey = dayKey
            recovered.recoveryHoldDayKey = dayKey
            recovered.nextResetAt = nil
            recovered.firstFailure = nil
            recovered.lastWarmupTargetAt = min(recovered.lastWarmupTargetAt ?? now, now)
            recovered.lastWarmupAttemptAt = recovered.lastWarmupAttemptAt ?? now
            recovered.lastRecord = WarmupRecord(timestamp: now, status: .failed,
                message: "기록 복구 완료 · 오늘 자동 워밍 중지. 미확인 전송의 상태를 먼저 확인해 주세요.")
            try recovered.validate()
            if try readFile(Self.migrationFile) == nil {
                try writeRecord(Migration(completed: false, settings: settings, cycle: recovered,
                                          originalSettings: defaults.object(forKey: "scheduleSettings") as? Data,
                                          originalCycle: defaults.object(forKey: "dailyCycle") as? Data), file: Self.migrationFile)
            }
            if try preferenceData(Self.settingsKey) == nil {
                defaults.set(try encoder.encode(StoredRecord(value: settings)), forKey: Self.settingsKey)
            }
            // 손상된 현재 파일로 마지막 정상 백업을 덮어쓰지 않는다.
            try writeRecord(recovered, file: Self.runtimeFile)
            prepare()
            return issue == nil
        } catch { setIssue(problem(error, area: .runtime)); return false }
    }

    private func preservePreferences(named name: String) throws {
        let keys = [Self.settingsKey, "scheduleSettings", "dailyCycle"]
        let originals = defaults.dictionaryRepresentation().filter { keys.contains($0.key) }
        let data = try PropertyListSerialization.data(fromPropertyList: originals, format: .binary, options: 0)
        try writeFile(data, name: "\(name)-\(UUID().uuidString).plist")
    }

    private func prepare() {
        issue = nil
        hasReadableSettings = false
        hasReadableCycle = false
        var currentSettings: Data?
        var currentCycle: Data?
        var migration: Migration?
        var problems: [StorageIssue] = []
        func capture(_ area: StorageIssue.Area, _ body: () throws -> Void) {
            do { try body() } catch { problems.append(problem(error, area: area)) }
        }
        capture(.settings) {
            currentSettings = try preferenceData(Self.settingsKey)
            if let currentSettings {
                settings = try decodeRecord(ScheduleSettings.self, currentSettings, area: .settings)
                try settings.validate()
                hasReadableSettings = true
            }
        }
        capture(.runtime) {
            currentCycle = try readFile(Self.runtimeFile)
            if let currentCycle {
                cycle = try decodeRecord(DailyCycle.self, currentCycle, area: .runtime)
                try cycle.validate()
                hasReadableCycle = true
            }
        }
        capture(.migration) {
            if let data = try readFile(Self.migrationFile) {
                migration = try decodeRecord(Migration.self, data, area: .migration)
                try migration!.settings.validate()
                try migration!.cycle.validate()
            }
        }
        // 미래 형식은 다른 손상보다 우선한다. 복구 동작으로도 덮어쓰지 않는다.
        if let failure = problems.first(where: { $0.kind == .unsupported }) ?? problems.first {
            setIssue(failure)
            return
        }
        if hasReadableSettings, hasReadableCycle {
            if var migration, !migration.completed {
                do {
                    migration.completed = true
                    try writeRecord(migration, file: Self.migrationFile)
                } catch { setIssue(problem(error, area: .migration)); return }
            }
            disposition = .valid
            return
        }
        if migration?.completed == true || (migration == nil && (currentSettings != nil || currentCycle != nil)) {
            setIssue(StorageIssue(area: hasReadableSettings ? .runtime : .settings, kind: .corrupt,
                                  detail: "이전에 저장된 데이터가 사라졌습니다. 구형 기록으로 자동 되돌리지 않습니다."))
            return
        }
        do {
            if migration == nil {
                var legacySettings: Data?
                var legacyCycle: Data?
                // 두 레코드를 모두 검증한 뒤에만 이전 파일을 만든다.
                var legacyProblems: [StorageIssue] = []
                do {
                    legacySettings = try preferenceData("scheduleSettings")
                    settings = try legacySettings.map { try decoder.decode(ScheduleSettings.self, from: $0) } ?? ScheduleSettings()
                    try settings.validate()
                    hasReadableSettings = true
                } catch { legacyProblems.append(problem(error, area: .settings)) }
                do {
                    legacyCycle = try preferenceData("dailyCycle")
                    cycle = try legacyCycle.map { try decoder.decode(DailyCycle.self, from: $0) } ?? DailyCycle()
                    try cycle.validate()
                    // 이 호환 처리는 버전 없는 구형 레코드 이전에만 적용한다.
                    if cycle.lastWarmupAttemptAt == nil,
                       cycle.lastRecord?.status == .succeeded || cycle.lastRecord?.status == .satisfied {
                        cycle.lastConfirmedResetAt = cycle.lastConfirmedResetAt ?? cycle.nextResetAt
                        cycle.lastWarmupTargetAt = nil
                    }
                    hasReadableCycle = true
                } catch { legacyProblems.append(problem(error, area: .runtime)) }
                if let failure = legacyProblems.first { setIssue(failure); return }
                disposition = legacySettings == nil && legacyCycle == nil ? .missing : .migrationNeeded
                migration = Migration(completed: false, settings: settings, cycle: cycle,
                                      originalSettings: legacySettings, originalCycle: legacyCycle)
                try writeRecord(migration!, file: Self.migrationFile)
            } else {
                disposition = .migrationNeeded
            }
            guard var migration else { return }
            if currentCycle == nil { try writeRecord(migration.cycle, file: Self.runtimeFile) }
            if currentSettings == nil {
                defaults.set(try encoder.encode(StoredRecord(value: migration.settings)), forKey: Self.settingsKey)
            }
            guard let savedSettings = try preferenceData(Self.settingsKey), let savedCycle = try readFile(Self.runtimeFile) else {
                throw StoredValueError.invalid("이전한 기록을 다시 읽지 못했습니다.")
            }
            settings = try decodeRecord(ScheduleSettings.self, savedSettings, area: .settings)
            cycle = try decodeRecord(DailyCycle.self, savedCycle, area: .runtime)
            try settings.validate()
            try cycle.validate()
            guard settings == migration.settings, cycle == migration.cycle else {
                throw StoredValueError.invalid("이전한 기록의 재읽기 결과가 일치하지 않습니다.")
            }
            migration.completed = true
            try writeRecord(migration, file: Self.migrationFile)
            hasReadableSettings = true
            hasReadableCycle = true
        } catch { setIssue(problem(error, area: .migration)) }
    }

    @discardableResult
    func saveSettings(_ value: ScheduleSettings) -> Bool {
        guard issue == nil else { return false }
        do {
            try value.validate()
            guard let previous = try preferenceData(Self.settingsKey) else {
                throw StoredValueError.invalid("예약 설정 레코드가 사라졌습니다.")
            }
            try decodeRecord(ScheduleSettings.self, previous, area: .settings).validate()
            defaults.set(try encoder.encode(StoredRecord(value: value)), forKey: Self.settingsKey)
            settings = value
            return true
        } catch { setIssue(problem(error, area: .settings)); return false }
    }

    @discardableResult
    func saveDailyCycle(_ value: DailyCycle) -> Bool {
        guard issue == nil else { return false }
        do {
            try value.validate()
            // 이미 저장된 파일이 외부에서 손상되었으면 백업까지 덮어쓰지 않는다.
            guard let previous = try readFile(Self.runtimeFile) else {
                throw StoredValueError.invalid("실행 기록 파일이 사라졌습니다.")
            }
            let previousCycle = try decodeRecord(DailyCycle.self, previous, area: .runtime)
            try previousCycle.validate()
            try writeFile(previous, name: Self.backupFile)
            try writeRecord(value, file: Self.runtimeFile)
            cycle = value
            return true
        } catch { setIssue(problem(error, area: .runtime)); return false }
    }

    func loadQuotaCache() -> QuotaCache? {
        guard let data = defaults.data(forKey: "quotaCache"),
              let cache = try? decoder.decode(QuotaCache.self, from: data), cache.isValid else { return nil }
        return cache
    }

    func saveQuotaCache(_ cache: QuotaCache) {
        guard issue == nil, cache.isValid, let data = try? encoder.encode(cache) else { return }
        defaults.set(data, forKey: "quotaCache")
    }

    func clearQuotaCache() { defaults.removeObject(forKey: "quotaCache") }

    /// 앱 실행 중 파일이 바뀌어도 캐시된 정상 상태로 인증·전송을 시작하지 않는다.
    @discardableResult
    func validateCurrentRecords() -> Bool {
        guard issue == nil else { return false }
        var area = StorageIssue.Area.settings
        do {
            guard let data = try preferenceData(Self.settingsKey) else {
                throw StoredValueError.invalid("예약 설정이 사라졌습니다.")
            }
            let savedSettings = try decodeRecord(ScheduleSettings.self, data, area: .settings)
            try savedSettings.validate()
            guard savedSettings == settings else { throw StoredValueError.invalid("예약 설정이 외부에서 변경되었습니다. 앱을 다시 실행해 주세요.") }
            area = .runtime
            guard let data = try readFile(Self.runtimeFile) else {
                throw StoredValueError.invalid("실행 기록이 사라졌습니다.")
            }
            let savedCycle = try decodeRecord(DailyCycle.self, data, area: .runtime)
            try savedCycle.validate()
            guard savedCycle == cycle else { throw StoredValueError.invalid("실행 기록이 외부에서 변경되었습니다. 앱을 다시 실행해 주세요.") }
            return true
        } catch { setIssue(problem(error, area: area)); return false }
    }

    private func decodeRecord<Value: Codable>(_ type: Value.Type, _ data: Data, area: StorageIssue.Area) throws -> Value {
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == 1, header.minimumReaderVersion == 1 else {
            if header.schemaVersion > 1 || header.minimumReaderVersion > 1 {
                throw StorageIssue(area: area, kind: .unsupported, detail: "지원하지 않는 저장 형식")
            }
            throw StoredValueError.invalid("저장 형식 번호가 올바르지 않습니다.")
        }
        return try decoder.decode(StoredRecord<Value>.self, from: data).value
    }

    private func preferenceData(_ key: String) throws -> Data? {
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let data = object as? Data else {
            throw StoredValueError.invalid("설정 레코드의 자료형이 올바르지 않습니다.")
        }
        return data
    }

    private func readFile(_ name: String) throws -> Data? {
        guard let directory else { return try preferenceData("isolated.\(name)") }
        do { return try Data(contentsOf: directory.appendingPathComponent(name)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private func writeFile(_ data: Data, name: String) throws {
        if let directory { try fileWriter(data, directory.appendingPathComponent(name)) }
        else { defaults.set(data, forKey: "isolated.\(name)") }
    }

    private func writeRecord<Value: Codable>(_ value: Value, file: String) throws {
        try writeFile(encoder.encode(StoredRecord(value: value)), name: file)
    }

    private func setIssue(_ failure: StorageIssue) {
        issue = failure
        disposition = failure.kind == .unsupported ? .unsupported : .corrupt
    }

    private func problem(_ error: Error, area: StorageIssue.Area) -> StorageIssue {
        if let issue = error as? StorageIssue { return issue }
        if case let StoredValueError.invalid(detail) = error { return StorageIssue(area: area, kind: .corrupt, detail: detail) }
        if error is DecodingError { return StorageIssue(area: area, kind: .corrupt, detail: "저장된 내용이 손상되었습니다.") }
        let nsError = error as NSError
        return StorageIssue(area: area, kind: .unavailable, detail: "저장소 오류 \(nsError.domain) (\(nsError.code))")
    }
}
