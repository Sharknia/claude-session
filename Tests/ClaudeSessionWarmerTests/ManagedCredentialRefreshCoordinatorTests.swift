import XCTest
import Security
@testable import ClaudeSessionWarmer

@MainActor
final class ManagedCredentialRefreshCoordinatorTests: XCTestCase {
    func testRotatedCredentialSurvivesSaveFailureWithoutAnotherRemoteRefresh() async throws {
        let coordinator = ManagedCredentialRefreshCoordinator()
        let store = PendingSaveFixture()
        do {
            _ = try await coordinator.run {
                let rotated = await store.refresh()
                try await coordinator.persist(rotated) { try await store.save($0) }
                return rotated
            }
            XCTFail("첫 저장은 실패해야 한다")
        } catch {
            XCTAssertEqual(error as? ClaudeServiceError, .credentialsUnavailable(errSecNotAvailable))
        }
        _ = try await coordinator.run {
            try await coordinator.retryPendingSave { try await store.save($0) }
            let current = await store.read()
            if current.needsRefresh() { return await store.refresh() }
            return current
        }
        let saved = await store.read()
        let refreshes = await store.refreshes
        XCTAssertEqual(saved.refreshToken, "rotated-fixture")
        XCTAssertEqual(refreshes, 1)
    }

    func testConcurrentRotationsReadPreviouslySavedCredential() async throws {
        let coordinator = ManagedCredentialRefreshCoordinator()
        let store = RotationFixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try await coordinator.run {
                        let current = await store.read()
                        // HTTP 응답과 Keychain 저장 사이에도 다른 읽기가 들어오면 안 된다.
                        try await Task.sleep(for: .milliseconds(3))
                        return try await store.rotateAndSave(current)
                    }
                }
            }
            try await group.waitForAll()
        }
        let count = await store.rotations
        XCTAssertEqual(count, 12)
    }

    func testConcurrentExpiryChecksRefreshOnlyOnceAfterSave() async throws {
        let coordinator = ManagedCredentialRefreshCoordinator()
        let store = RotationFixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try await coordinator.run {
                        let current = await store.read()
                        guard current.needsRefresh() else { return current }
                        try await Task.sleep(for: .milliseconds(3))
                        return try await store.rotateAndSave(current)
                    }
                }
            }
            try await group.waitForAll()
        }
        let count = await store.rotations
        XCTAssertEqual(count, 1)
    }

    func testFailureReleasesCoordinatorForNextAttempt() async throws {
        let coordinator = ManagedCredentialRefreshCoordinator()
        do {
            _ = try await coordinator.run { throw ClaudeServiceError.oauthRefreshFailed }
            XCTFail("실패가 전달돼야 한다")
        } catch {
            XCTAssertEqual(error as? ClaudeServiceError, .oauthRefreshFailed)
        }
        let store = RotationFixture()
        _ = try await coordinator.run { await store.read() }
    }
}

private actor PendingSaveFixture {
    private var credential = ManagedClaudeCredential(accessToken: "old", refreshToken: "old",
                                                    expiresAtMilliseconds: 0, scopes: [])
    private var failNextSave = true
    private(set) var refreshes = 0
    func read() -> ManagedClaudeCredential { credential }
    func refresh() -> ManagedClaudeCredential {
        refreshes += 1
        return ManagedClaudeCredential(accessToken: "rotated-fixture", refreshToken: "rotated-fixture",
                                       expiresAtMilliseconds: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
                                       scopes: [])
    }
    func save(_ credential: ManagedClaudeCredential) throws {
        if failNextSave {
            failNextSave = false
            throw ClaudeServiceError.credentialsUnavailable(errSecNotAvailable)
        }
        self.credential = credential
    }
}

private actor RotationFixture {
    private var credential = ManagedClaudeCredential(
        accessToken: "fixture-0", refreshToken: "fixture-0",
        expiresAtMilliseconds: 0, scopes: ["user:inference"]
    )
    private(set) var rotations = 0

    func read() -> ManagedClaudeCredential { credential }

    func rotateAndSave(_ previous: ManagedClaudeCredential) throws -> ManagedClaudeCredential {
        guard previous == credential else { throw ClaudeServiceError.oauthRefreshFailed }
        rotations += 1
        credential = ManagedClaudeCredential(
            accessToken: "fixture-\(rotations)", refreshToken: "fixture-\(rotations)",
            expiresAtMilliseconds: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            scopes: previous.scopes
        )
        return credential
    }
}
