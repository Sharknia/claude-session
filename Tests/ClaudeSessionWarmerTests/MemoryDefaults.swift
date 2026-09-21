import Foundation

/// CFPreferences에 도메인을 등록하지 않는 테스트 전용 저장소.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let memoryLock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? {
        memoryLock.withLock { values[key] }
    }

    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

    override func set(_ value: Any?, forKey key: String) {
        memoryLock.withLock { values[key] = value }
    }

    override func removeObject(forKey key: String) {
        _ = memoryLock.withLock { values.removeValue(forKey: key) }
    }

    override func removePersistentDomain(forName name: String) {
        memoryLock.withLock { values.removeAll() }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        memoryLock.withLock { values }
    }
}
