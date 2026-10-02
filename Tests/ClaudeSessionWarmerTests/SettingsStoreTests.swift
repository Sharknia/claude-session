import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        defaults = MemoryDefaults()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLegacyCyclePreservesCountAndOnlyClearsConfirmedTransmission() throws {
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        for status in [WarmupStatus.succeeded, .satisfied, .failed, .checking, .missed] {
            defaults = MemoryDefaults()
            let legacy: [String: Any] = [
                "dayKey": "2027-01-15", "handledWindows": 2,
                "nextResetAt": target.addingTimeInterval(18_000).timeIntervalSinceReferenceDate,
                "lastWarmupTargetAt": target.timeIntervalSinceReferenceDate,
                "lastRecord": ["timestamp": target.timeIntervalSinceReferenceDate,
                               "status": status.rawValue, "message": "legacy"]
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "dailyCycle")
            let store = SettingsStore(defaults: defaults)
            let state = AppState(store: store, startScheduler: false)
            XCTAssertEqual(state.cycle.handledWindows, 2)
            XCTAssertEqual(state.cycle.dayKey, "2027-01-15")
            XCTAssertEqual(state.cycle.nextResetAt, target.addingTimeInterval(18_000))
            XCTAssertEqual(state.hasUnconfirmedWarmup, status != .succeeded && status != .satisfied)
        }
    }

    @MainActor
    func testNewPendingTransmissionIsNotErasedByOlderSuccessRecord() {
        let store = SettingsStore(defaults: defaults)
        let target = Date()
        store.saveDailyCycle(DailyCycle(lastWarmupTargetAt: target,
            lastRecord: WarmupRecord(timestamp: target.addingTimeInterval(-3600), status: .succeeded, message: "previous"),
            lastWarmupAttemptAt: target))
        let state = AppState(store: store, startScheduler: false)
        XCTAssertTrue(state.hasUnconfirmedWarmup)
        XCTAssertEqual(state.cycle.lastWarmupAttemptAt, target)
    }

    func testDefaultsMatchMVPPolicy() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.loadSettings(), ScheduleSettings())
        XCTAssertEqual(store.loadSettings().firstWarmupMinutes, 6 * 60)
        XCTAssertEqual(store.loadSettings().weekdays, [2, 3, 4, 5, 6])
        XCTAssertTrue(store.loadSettings().excludeKoreanHolidays)
        XCTAssertFalse(store.loadSettings().launchAtLogin)
        XCTAssertEqual(store.loadDailyCycle(), DailyCycle())
        XCTAssertNil(store.loadQuotaCache())
    }

    func testSettingsRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        let settings = ScheduleSettings(
            firstWarmupMinutes: 8 * 60 + 30,
            weekdays: [2, 4, 6],
            excludeKoreanHolidays: false,
            launchAtLogin: true
        )

        store.saveSettings(settings)

        XCTAssertEqual(store.loadSettings(), settings)
    }

    func testDailyCycleRoundTripAndWindowCountIsBounded() {
        let store = SettingsStore(defaults: defaults)
        let record = WarmupRecord(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            status: .succeeded,
            message: "warmup completed"
        )
        let cycle = DailyCycle(
            dayKey: "2026-09-04",
            handledWindows: 2,
            nextResetAt: Date(timeIntervalSince1970: 1_800_018_000),
            lastWarmupTargetAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastRecord: record
        )

        store.saveDailyCycle(cycle)

        XCTAssertEqual(store.loadDailyCycle(), cycle)
        XCTAssertEqual(DailyCycle(handledWindows: -1).handledWindows, 0)
        XCTAssertEqual(DailyCycle(handledWindows: 4).handledWindows, 3)
    }

    func testQuotaCacheRoundTripAndClearDoNotChangeSettings() {
        let store = SettingsStore(defaults: defaults)
        let settings = ScheduleSettings(
            firstWarmupMinutes: 9 * 60,
            weekdays: [2, 3, 4],
            excludeKoreanHolidays: false,
            launchAtLogin: false
        )
        let cache = QuotaCache(
            quota: QuotaWindow(
                active: true,
                usedPercent: 23,
                resetsAt: Date(timeIntervalSince1970: 1_800_018_000)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        store.saveSettings(settings)
        store.saveQuotaCache(cache)

        XCTAssertEqual(store.loadQuotaCache(), cache)
        XCTAssertEqual(store.loadSettings(), settings)

        store.clearQuotaCache()

        XCTAssertNil(store.loadQuotaCache())
        XCTAssertEqual(store.loadSettings(), settings)
    }

    func testPersistedModelsContainOnlyExpectedFields() throws {
        let scheduleKeys = Set(try jsonObjectKeys(for: ScheduleSettings()))
        let cycleKeys = Set(try jsonObjectKeys(for: DailyCycle()))
        let quotaCacheKeys = Set(try jsonObjectKeys(for: QuotaCache(
            quota: QuotaWindow(active: false, usedPercent: nil, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 0)
        )))

        XCTAssertEqual(
            scheduleKeys,
            ["firstWarmupMinutes", "weekdays", "excludeKoreanHolidays", "launchAtLogin", "sleepPrevention"]
        )
        XCTAssertEqual(
            cycleKeys,
            ["handledWindows"]
        )
        XCTAssertEqual(quotaCacheKeys, ["quota", "fetchedAt"])

        let persistedKeys = scheduleKeys.union(cycleKeys).union(quotaCacheKeys)
        XCTAssertTrue(persistedKeys.isDisjoint(with: [
            "token", "accessToken", "refreshToken", "oauthToken", "apiKey", "authorization"
        ]))
    }

    func testSettingsRecordWithoutSleepPreventionReadsAsOff() {
        seedCurrentRecords()
        defaults.set(settingsRecord(extraFields: ""), forKey: SettingsStore.settingsKey)

        let store = SettingsStore(defaults: defaults)

        XCTAssertNil(store.issue)
        XCTAssertEqual(store.loadSettings().sleepPrevention, .off)
        XCTAssertEqual(store.loadSettings().firstWarmupMinutes, 480)
        XCTAssertEqual(store.loadSettings().weekdays, [2, 3])
        XCTAssertTrue(store.loadSettings().launchAtLogin)
        // 키가 없는 레코드를 "외부에서 변경됨"으로 오판하지 않는다.
        XCTAssertTrue(store.validateCurrentRecords())
    }

    func testLegacyVersionlessSettingsReadAsOff() {
        let legacy = #"{"firstWarmupMinutes":480,"weekdays":[2,3],"excludeKoreanHolidays":false,"launchAtLogin":true}"#
        defaults.set(Data(legacy.utf8), forKey: "scheduleSettings")

        let store = SettingsStore(defaults: defaults)

        XCTAssertNil(store.issue)
        XCTAssertEqual(store.loadSettings().sleepPrevention, .off)
        XCTAssertEqual(store.loadSettings().firstWarmupMinutes, 480)
        // 이전이 끝난 뒤 다시 열어도 같은 값이다.
        let restarted = SettingsStore(defaults: defaults)
        XCTAssertNil(restarted.issue)
        XCTAssertEqual(restarted.loadSettings().sleepPrevention, .off)
    }

    func testSleepPreventionRoundTrip() {
        for mode in SleepPreventionMode.allCases {
            let roundTripDefaults = MemoryDefaults()
            let store = SettingsStore(defaults: roundTripDefaults)

            XCTAssertTrue(store.saveSettings(ScheduleSettings(sleepPrevention: mode)), "\(mode)")

            let reopened = SettingsStore(defaults: roundTripDefaults)
            XCTAssertNil(reopened.issue, "\(mode)")
            XCTAssertEqual(reopened.loadSettings().sleepPrevention, mode)
        }
    }

    func testUnknownSleepPreventionValueIsReportedAsCorruptNotSilentlyOff() {
        seedCurrentRecords()
        defaults.set(settingsRecord(extraFields: #","sleepPrevention":"someFutureMode""#),
                     forKey: SettingsStore.settingsKey)

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.issue?.area, .settings)
        XCTAssertEqual(store.issue?.kind, .corrupt)
        // 손상 상태의 반환값은 초안 기본값이다. 미지 값을 조용히 끔으로 읽은 것이 아니다.
        XCTAssertEqual(store.loadSettings().sleepPrevention, .off)
        XCTAssertEqual(store.loadSettings().firstWarmupMinutes, 6 * 60)
    }

    func testNullSleepPreventionReadsAsOffAndWrongTypeIsCorrupt() {
        seedCurrentRecords()
        defaults.set(settingsRecord(extraFields: #","sleepPrevention":null"#), forKey: SettingsStore.settingsKey)
        let nullStore = SettingsStore(defaults: defaults)
        XCTAssertNil(nullStore.issue)
        XCTAssertEqual(nullStore.loadSettings().sleepPrevention, .off)

        defaults.set(settingsRecord(extraFields: #","sleepPrevention":1"#), forKey: SettingsStore.settingsKey)
        XCTAssertEqual(SettingsStore(defaults: defaults).issue?.kind, .corrupt)
    }

    /// 실행 기록과 이전 기록까지 갖춘 정상 상태를 만든다. 이후 예약 설정 레코드만 바꿔 쓴다.
    private func seedCurrentRecords() {
        _ = SettingsStore(defaults: defaults)
    }

    /// 헤더 1·1과 0.1.7의 네 필드를 가진 레코드. `extraFields`는 `,"키":값` 형태로 덧붙인다.
    private func settingsRecord(extraFields: String) -> Data {
        let base = #""firstWarmupMinutes":480,"weekdays":[2,3],"excludeKoreanHolidays":false,"launchAtLogin":true"#
        return Data(#"{"schemaVersion":1,"minimumReaderVersion":1,"value":{\#(base)\#(extraFields)}}"#.utf8)
    }

    private func jsonObjectKeys<Value: Encodable>(for value: Value) throws -> [String] {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Array(object.keys)
    }
}
