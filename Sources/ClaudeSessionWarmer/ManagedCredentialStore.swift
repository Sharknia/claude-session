import Foundation
import Security

/// 새 저장소가 없을 때만 기존 앱 항목을 이전한다. 접근 거부는 항목 부재와 구별한다.
struct ManagedCredentialStore {
    var queries = ClaudeCredentialQueries()
    var copy: ([CFString: Any]) -> (OSStatus, Data?) = { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    var update: ([CFString: Any], [CFString: Any]) -> OSStatus = {
        SecItemUpdate($0 as CFDictionary, $1 as CFDictionary)
    }
    var add: ([CFString: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) }
    var delete: ([CFString: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }

    func read() throws -> ManagedClaudeCredential {
        let (status, data) = copy(queries.cacheRead())
        log("read", status: status)
        if status == errSecSuccess { return try decode(data) }
        guard status == errSecItemNotFound else { throw ClaudeServiceError.credentialsUnavailable(status) }

        let (legacyStatus, legacyData) = copy(queries.cacheRead(legacy: true))
        log("read", status: legacyStatus, legacy: true)
        guard legacyStatus != errSecItemNotFound else { throw ClaudeServiceError.managedCredentialsUnavailable }
        guard legacyStatus == errSecSuccess else { throw ClaudeServiceError.credentialsUnavailable(legacyStatus) }
        let credential = try decode(legacyData)
        try save(credential)
        let (verifyStatus, verifiedData) = copy(queries.cacheRead())
        log("verify_migration", status: verifyStatus)
        guard verifyStatus == errSecSuccess else { throw ClaudeServiceError.credentialsUnavailable(verifyStatus) }
        guard try decode(verifiedData) == credential else { throw ClaudeServiceError.credentialsUnavailable(errSecDecode) }
        // 새 저장소에서 동일한 인증 정보를 읽은 뒤에만 구버전의 회전 토큰을 제거한다.
        log("delete_migrated", status: delete(queries.cacheUpdateQuery(legacy: true)), legacy: true)
        diagnosticLog("keychain.migrated", ["operation_id": DiagnosticContext.operationID ?? "none"])
        return credential
    }

    func save(_ credential: ManagedClaudeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = update(queries.cacheUpdateQuery(), [kSecValueData: data])
        log("update", status: status)
        if status == errSecItemNotFound {
            let addStatus = add(queries.cacheAddPayload(data: data))
            log("add", status: addStatus)
            guard addStatus == errSecSuccess else { throw ClaudeServiceError.credentialsUnavailable(addStatus) }
        } else if status != errSecSuccess {
            throw ClaudeServiceError.credentialsUnavailable(status)
        }
    }

    private func decode(_ data: Data?) throws -> ManagedClaudeCredential {
        guard let data else { throw ClaudeServiceError.credentialsUnavailable(errSecDecode) }
        return try ClaudeService.parseManagedCredential(from: data)
    }

    private func log(_ operation: String, status: OSStatus, legacy: Bool = false) {
        diagnosticLog("keychain.operation", [
            "operation_id": DiagnosticContext.operationID ?? "none", "operation": operation,
            "backend": legacy ? "legacy" : "data_protection", "os_status": "\(status)"
        ])
    }
}
