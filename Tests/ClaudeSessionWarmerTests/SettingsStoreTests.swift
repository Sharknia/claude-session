import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsMatchMVPPolicy() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.loadSettings(), ScheduleSettings())
        XCTAssertEqual(store.loadSettings().firstWarmupMinutes, 6 * 60)
        XCTAssertEqual(store.loadSettings().weekdays, [2, 3, 4, 5, 6])
        XCTAssertTrue(store.loadSettings().excludeKoreanHolidays)
        XCTAssertFalse(store.loadSettings().launchAtLogin)
        XCTAssertEqual(store.loadDailyCycle(), DailyCycle())
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

    func testPersistedModelsContainOnlyExpectedFields() throws {
        let scheduleKeys = Set(try jsonObjectKeys(for: ScheduleSettings()))
        let cycleKeys = Set(try jsonObjectKeys(for: DailyCycle()))

        XCTAssertEqual(
            scheduleKeys,
            ["firstWarmupMinutes", "weekdays", "excludeKoreanHolidays", "launchAtLogin"]
        )
        XCTAssertEqual(
            cycleKeys,
            ["handledWindows"]
        )

        let persistedKeys = scheduleKeys.union(cycleKeys)
        XCTAssertTrue(persistedKeys.isDisjoint(with: [
            "token", "accessToken", "refreshToken", "oauthToken", "apiKey", "authorization"
        ]))
    }

    private func jsonObjectKeys<Value: Encodable>(for value: Value) throws -> [String] {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Array(object.keys)
    }
}
