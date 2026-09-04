import Foundation

final class SettingsStore {
    private enum Key {
        static let scheduleSettings = "scheduleSettings"
        static let dailyCycle = "dailyCycle"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSettings() -> ScheduleSettings {
        decode(ScheduleSettings.self, forKey: Key.scheduleSettings) ?? ScheduleSettings()
    }

    func saveSettings(_ settings: ScheduleSettings) {
        encode(settings, forKey: Key.scheduleSettings)
    }

    func loadDailyCycle() -> DailyCycle {
        decode(DailyCycle.self, forKey: Key.dailyCycle) ?? DailyCycle()
    }

    func saveDailyCycle(_ cycle: DailyCycle) {
        encode(cycle, forKey: Key.dailyCycle)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
