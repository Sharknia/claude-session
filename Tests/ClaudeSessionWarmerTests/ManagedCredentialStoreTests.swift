import Security
import XCTest
@testable import ClaudeSessionWarmer

final class ManagedCredentialStoreTests: XCTestCase {
    private let credential = ManagedClaudeCredential(
        accessToken: "fixture-access", refreshToken: "fixture-refresh",
        expiresAtMilliseconds: 1_900_000_000_000, scopes: ["user:inference"]
    )

    func testMigrationVerifiesCredentialBeforeRemovingLegacyAndNeverReadsLegacyAgain() throws {
        let f = KeychainFixture()
        f.legacy = try JSONEncoder().encode(credential)
        let store = f.store()
        XCTAssertEqual(try store.read(), credential)
        XCTAssertEqual(try JSONDecoder().decode(ManagedClaudeCredential.self, from: XCTUnwrap(f.protected)), credential)
        XCTAssertNil(f.legacy)
        XCTAssertEqual(f.accessibility, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let legacyReads = f.legacyReads
        XCTAssertEqual(try store.read(), credential)
        XCTAssertEqual(f.legacyReads, legacyReads)
    }

    func testUnavailableProtectedStoreDoesNotFallBackToLegacyOrEraseEitherStore() throws {
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecAuthFailed] {
            let f = KeychainFixture()
            let data = try JSONEncoder().encode(credential)
            f.legacy = data
            f.protectedReadError = status
            XCTAssertThrowsError(try f.store().read()) {
                XCTAssertEqual($0 as? ClaudeServiceError, .credentialsUnavailable(status))
            }
            XCTAssertEqual(f.legacyReads, 0)
            XCTAssertEqual(f.legacy, data)
            XCTAssertNil(f.protected)
        }
    }

    func testFailedMigrationWriteOrReadbackPreservesLegacyCredential() throws {
        for failWrite in [true, false] {
            let f = KeychainFixture()
            let data = try JSONEncoder().encode(credential)
            f.legacy = data
            if failWrite { f.writeError = errSecNotAvailable }
            else { f.failReadback = true }
            XCTAssertThrowsError(try f.store().read()) {
                XCTAssertEqual($0 as? ClaudeServiceError, .credentialsUnavailable(errSecNotAvailable))
            }
            XCTAssertEqual(f.legacy, data)
        }
    }

    func testSaveFailureKeepsOriginalStatusAndDoesNotWriteLegacy() throws {
        let f = KeychainFixture()
        f.writeError = errSecMissingEntitlement
        XCTAssertThrowsError(try f.store().save(credential)) {
            XCTAssertEqual($0 as? ClaudeServiceError, .credentialsUnavailable(errSecMissingEntitlement))
        }
        XCTAssertNil(f.legacy)
        XCTAssertNil(f.protected)
    }
}

private final class KeychainFixture {
    var protected: Data?
    var legacy: Data?
    var accessibility: String?
    var protectedReadError: OSStatus?
    var writeError: OSStatus?
    var failReadback = false
    var legacyReads = 0

    func store() -> ManagedCredentialStore {
        ManagedCredentialStore(copy: { query in
            if query[kSecUseDataProtectionKeychain] as? Bool == true {
                if let error = self.protectedReadError { return (error, nil) }
                if self.failReadback, self.protected != nil { return (errSecNotAvailable, nil) }
                return (self.protected == nil ? errSecItemNotFound : errSecSuccess, self.protected)
            }
            self.legacyReads += 1
            return (self.legacy == nil ? errSecItemNotFound : errSecSuccess, self.legacy)
        }, update: { query, values in
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
            if let error = self.writeError { return error }
            guard self.protected != nil else { return errSecItemNotFound }
            self.protected = values[kSecValueData] as? Data
            return errSecSuccess
        }, add: { query in
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
            if let error = self.writeError { return error }
            self.accessibility = query[kSecAttrAccessible] as? String
            self.protected = query[kSecValueData] as? Data
            return errSecSuccess
        }, delete: { query in
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, false)
            XCTAssertNotNil(self.protected)
            self.legacy = nil
            return errSecSuccess
        })
    }
}
