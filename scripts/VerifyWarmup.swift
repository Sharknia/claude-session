import Foundation
import Security

/// 앱과 같은 서명으로 빌드해 실제 Keychain과 서비스 코드를 검증한다.
/// 토큰, 프롬프트, CLI 출력은 기록하지 않는다.
@main
struct VerifyWarmup {
    static func main() async {
        let operationID = UUID().uuidString
        do {
            try await DiagnosticContext.$operationID.withValue(operationID) {
                if CommandLine.arguments.contains("--storage-probe") {
                    // 실제 계정과 분리한 임시 항목으로 서명·저장 위치·접근 정책을 검증한다.
                    let queries = ClaudeCredentialQueries(
                        service: "com.sharknia.ClaudeSessionWarmer.probe.\(UUID().uuidString)", account: "probe"
                    )
                    let store = ManagedCredentialStore(queries: queries)
                    defer {
                        _ = SecItemDelete(queries.cacheUpdateQuery() as CFDictionary)
                        _ = SecItemDelete(queries.cacheUpdateQuery(legacy: true) as CFDictionary)
                    }
                    let credential = ManagedClaudeCredential(accessToken: "probe", refreshToken: "probe",
                                                             expiresAtMilliseconds: 0, scopes: [])
                    var legacy = queries.cacheUpdateQuery(legacy: true)
                    legacy[kSecValueData] = try JSONEncoder().encode(credential)
                    let seedStatus = SecItemAdd(legacy as CFDictionary, nil)
                    guard seedStatus == errSecSuccess else { throw ClaudeServiceError.credentialsUnavailable(seedStatus) }
                    guard try store.read() == credential else { throw ClaudeServiceError.credentialsUnavailable(errSecDecode) }
                    let legacyStatus = SecItemCopyMatching(queries.cacheRead(legacy: true) as CFDictionary, nil)
                    guard legacyStatus == errSecItemNotFound else { throw ClaudeServiceError.credentialsUnavailable(errSecDuplicateItem) }
                    let rotated = ManagedClaudeCredential(accessToken: "probe-rotated", refreshToken: "probe-rotated",
                                                          expiresAtMilliseconds: 1, scopes: [])
                    try store.save(rotated)
                    guard try store.read() == rotated else { throw ClaudeServiceError.credentialsUnavailable(errSecDecode) }
                    var query = queries.cacheUpdateQuery()
                    query[kSecReturnAttributes] = true
                    var result: CFTypeRef?
                    let status = SecItemCopyMatching(query as CFDictionary, &result)
                    guard status == errSecSuccess,
                          let attributes = result as? [String: Any],
                          attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String else {
                        throw ClaudeServiceError.credentialsUnavailable(status == errSecSuccess ? errSecParam : status)
                    }
                    print("result=storage_probe_pass; backend=data_protection; migration=verified; rotation=verified; accessible=after_first_unlock_this_device_only")
                    return
                }
                if CommandLine.arguments.contains("--keychain-only") {
                    _ = try ManagedCredentialStore().read()
                    print("result=managed_credential_read_pass; no_http_request=true")
                    return
                }
                let service = ClaudeService()
                let before = try await service.fetchManagedQuota()
                print("operation_id=\(operationID)")
                print("pre_active=\(before.active) resets_at=\(diagnosticDate(before.resetsAt))")
                let allowActive = CommandLine.arguments.contains("--allow-active")
                guard !before.active || allowActive else {
                    print("result=pending_inactive_window; no_warmup_performed=true")
                    DiagnosticLogger.shared.flush()
                    exit(2)
                }

                let command = ClaudeWarmupCommand.make(
                    executableURL: try service.locateCLI(),
                    oauthToken: try service.managedAccessToken()
                )
                try service.performWarmup(command: command)
                print("assistant_response_received=true")
                for attempt in 0..<6 {
                    if attempt > 0 { try await Task.sleep(for: .seconds(5)) }
                    let after = try await service.fetchManagedQuota()
                    if after.active, after.resetsAt != nil {
                        print("post_active=true resets_at=\(diagnosticDate(after.resetsAt))")
                        print(before.active ? "result=cli_only_pass; activation_unverified=true" : "result=inactive_to_active_pass")
                        return
                    }
                }
                throw ClaudeServiceError.warmupFailed
            }
        } catch {
            print("result=failed error=\(ClaudeService.diagnosticErrorCode(error))")
            DiagnosticLogger.shared.flush()
            exit(1)
        }
        DiagnosticLogger.shared.flush()
    }
}
