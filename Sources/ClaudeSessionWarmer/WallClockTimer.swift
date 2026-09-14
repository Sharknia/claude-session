import Foundation

/// 실제 날짜에 도달하면 한 번 호출한다. 시스템 잠자기 시간을 대기 시간에 더하지 않는다.
final class WallClockTimer {
    private static let queue = DispatchQueue(
        label: "com.sharknia.ClaudeSessionWarmer.scheduler", qos: .userInitiated
    )
    private let source: DispatchSourceTimer

    init(at date: Date, callback: @escaping @Sendable (Date) -> Void) {
        source = DispatchSource.makeTimerSource(queue: Self.queue)
        source.schedule(wallDeadline: Self.deadline(for: date), repeating: .never, leeway: .milliseconds(100))
        source.setEventHandler { callback(Date()) }
        source.resume()
    }

    static func deadline(for date: Date) -> DispatchWallTime {
        let seconds = floor(date.timeIntervalSince1970)
        let nanoseconds = Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000)
        return DispatchWallTime(timespec: timespec(tv_sec: Int(seconds), tv_nsec: nanoseconds))
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}
