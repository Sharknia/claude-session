import XCTest
@testable import ClaudeSessionWarmer

final class WallClockTimerTests: XCTestCase {
    func testWallDeadlinePreservesEpochSecondsAndNormalizesNegativeFractions() {
        for (timestamp, seconds, nanos) in [(1_800_000_000.25, 1_800_000_000, 250_000_000),
                                           (-0.25, -1, 750_000_000), (0.0, 0, 0)] {
            XCTAssertEqual(
                WallClockTimer.deadline(for: Date(timeIntervalSince1970: timestamp)),
                DispatchWallTime(timespec: timespec(tv_sec: seconds, tv_nsec: nanos))
            )
        }
    }

    func testTimerDeliversOnceOnBackgroundQueue() async {
        let fired = expectation(description: "실제 벽시계 타이머 콜백")
        fired.assertForOverFulfill = true
        let target = Date().addingTimeInterval(0.1)
        let timer = WallClockTimer(at: target) { at in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertLessThan(abs(at.timeIntervalSince(target)), 1)
            fired.fulfill()
        }
        await fulfillment(of: [fired], timeout: 2)
        withExtendedLifetime(timer) {}
    }

    func testCancellationAndDeallocationPreventDelivery() async {
        let fired = expectation(description: "취소된 타이머는 실행되지 않음")
        fired.isInverted = true
        let target = Date().addingTimeInterval(0.1)
        let cancelled = WallClockTimer(at: target) { _ in fired.fulfill() }
        cancelled.cancel()
        weak var weakTimer: WallClockTimer?
        do {
            let released = WallClockTimer(at: target) { _ in fired.fulfill() }
            weakTimer = released
        }
        XCTAssertNil(weakTimer)
        await fulfillment(of: [fired], timeout: 0.3)
        withExtendedLifetime(cancelled) {}
    }
}
