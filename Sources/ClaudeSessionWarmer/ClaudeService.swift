import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Darwin

private let claudeAuthEnvironmentKeys = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS"
]

enum ClaudeServiceError: LocalizedError, Equatable {
    case cliNotFound
    case credentialsUnavailable
    case managedCredentialsUnavailable
    case loginCaptureFailed
    case oauthLoginTimedOut
    case oauthRefreshFailed
    case invalidUsageResponse
    case quotaUnauthorized
    case quotaRateLimited
    case quotaUnavailable
    case warmupNotStarted
    case warmupTimedOut
    case warmupFailed

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "Claude CLI를 찾을 수 없습니다."
        case .credentialsUnavailable: return "앱 전용 Claude 인증 정보를 Keychain에서 읽거나 저장하지 못했습니다."
        case .managedCredentialsUnavailable: return "Claude 연결이 필요합니다. Claude 로그인을 눌러 주세요."
        case .loginCaptureFailed: return "Claude 로그인 뒤 OAuth 인증 정보를 가져오지 못했습니다."
        case .oauthLoginTimedOut: return "Claude 로그인이 시간 안에 완료되지 않았습니다. 다시 시도해 주세요."
        case .oauthRefreshFailed: return "Claude 연결을 갱신하지 못했습니다. Mac 잠금을 해제한 뒤 다시 연결해 주세요."
        case .invalidUsageResponse: return "사용량 응답 형식이 올바르지 않습니다."
        case .quotaUnauthorized: return "Claude 인증이 만료됐을 수 있습니다. Mac 잠금을 해제한 뒤 다시 연결해 주세요."
        case .quotaRateLimited: return "Claude 사용량 조회 요청이 제한되었습니다."
        case .quotaUnavailable: return "Claude 사용량 조회 서비스를 사용할 수 없습니다."
        case .warmupNotStarted: return "Claude 워밍 프로세스를 시작하지 못했습니다."
        case .warmupTimedOut: return "워밍 호출 시간이 초과되었습니다."
        case .warmupFailed: return "워밍 호출이 성공 마커를 반환하지 않았습니다."
        }
    }
}

struct ClaudeUsageAdapter {
    /// 비공개 API 형식은 이 어댑터 밖으로 노출하지 않는다.
    static func parseQuotaWindow(_ data: Data) throws -> QuotaWindow {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeServiceError.invalidUsageResponse
        }
        guard let root = object as? [String: Any] else {
            throw ClaudeServiceError.invalidUsageResponse
        }

        let rawFiveHour: Any?
        if root.keys.contains("five_hour") {
            rawFiveHour = root["five_hour"]
        } else if let limits = root["rate_limits"] as? [String: Any], limits.keys.contains("five_hour") {
            rawFiveHour = limits["five_hour"]
        } else {
            rawFiveHour = nil
        }
        guard let rawFiveHour else {
            throw ClaudeServiceError.invalidUsageResponse
        }
        if rawFiveHour is NSNull {
            return QuotaWindow(active: false, usedPercent: nil, resetsAt: nil)
        }
        guard let window = rawFiveHour as? [String: Any] else {
            throw ClaudeServiceError.invalidUsageResponse
        }
        let usedPercent: Double?
        if let rawUtilization = window["utilization"] {
            guard let utilization = rawUtilization as? NSNumber,
                  CFGetTypeID(utilization) != CFBooleanGetTypeID(),
                  (0...100).contains(utilization.doubleValue) else {
                throw ClaudeServiceError.invalidUsageResponse
            }
            usedPercent = utilization.doubleValue
        } else {
            usedPercent = nil
        }
        guard let rawReset = window["resets_at"], !(rawReset is NSNull) else {
            return QuotaWindow(active: false, usedPercent: usedPercent, resetsAt: nil)
        }
        guard let resetValue = rawReset as? String, let resetsAt = parseISO8601(resetValue) else {
            throw ClaudeServiceError.invalidUsageResponse
        }
        return QuotaWindow(active: true, usedPercent: usedPercent, resetsAt: resetsAt)
    }

    static func makeRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    static func diagnosticMetadata(_ data: Data) -> [String: String] {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var metadata = [
            "response_bytes": "\(data.count)",
            "response_sha256": digest
        ]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            metadata["shape"] = "invalid_json"
            return metadata
        }
        metadata["top_level_keys"] = root.keys.sorted().joined(separator: ",")

        let rawFiveHour: Any?
        if root.keys.contains("five_hour") {
            metadata["location"] = "top_level"
            rawFiveHour = root["five_hour"]
        } else if let limits = root["rate_limits"] as? [String: Any], limits.keys.contains("five_hour") {
            metadata["location"] = "rate_limits"
            rawFiveHour = limits["five_hour"]
        } else {
            metadata["shape"] = "missing"
            return metadata
        }

        if rawFiveHour is NSNull {
            metadata["shape"] = "null"
            return metadata
        }
        guard let window = rawFiveHour as? [String: Any] else {
            metadata["shape"] = "invalid_type"
            return metadata
        }
        metadata["shape"] = "object"
        metadata["five_hour_keys"] = window.keys.sorted().joined(separator: ",")
        metadata["utilization_field"] = fieldState(window["utilization"], expected: NSNumber.self)
        metadata["resets_at_field"] = fieldState(window["resets_at"], expected: NSString.self)
        return metadata
    }

    private static func fieldState<T>(_ value: Any?, expected: T.Type) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        return value is T ? "valid_type" : "invalid_type"
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct ClaudeWarmupCommand: Equatable {
    static let successMarker = "CW_WARMUP_OK"

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let prompt: String

    static func make(executableURL: URL, oauthToken: String? = nil, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeWarmupCommand {
        var environment = inheritedEnvironment
        claudeAuthEnvironmentKeys.forEach {
            environment.removeValue(forKey: $0)
        }
        environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
        if let oauthToken, !oauthToken.isEmpty {
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = oauthToken
        }
        return ClaudeWarmupCommand(
            executableURL: executableURL,
            arguments: ["--safe-mode", "--tools", "", "--model", "haiku", "--effort", "low"],
            environment: environment,
            prompt: "Confirm readiness using the uppercase ASCII token formed by C plus W, then an underscore, WARMUP, another underscore, and O plus K."
        )
    }
}

enum ClaudeCredentialQueries {
    static let cacheService = "com.sharknia.ClaudeSessionWarmer.oauth"
    static let cacheAccount = "claude-managed-credential"

    static func cacheRead() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cacheService,
            kSecAttrAccount: cacheAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: nonInteractiveContext()
        ]
    }

    static func cacheUpdateQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cacheService,
            kSecAttrAccount: cacheAccount
        ]
    }

    static func cacheAddPayload(data: Data) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cacheService,
            kSecAttrAccount: cacheAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ]
    }

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

struct ManagedClaudeCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAtMilliseconds: Int64?
    let scopes: [String]

    var expiresAt: Date? {
        expiresAtMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    func needsRefresh(now: Date = Date(), buffer: TimeInterval = 5 * 60) -> Bool {
        guard let expiresAt else { return true }
        return now.addingTimeInterval(buffer) >= expiresAt
    }
}

private actor ManagedCredentialRefreshCoordinator {
    private var inFlight: Task<ManagedClaudeCredential, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> ManagedClaudeCredential) async throws -> ManagedClaudeCredential {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

private struct KeychainStatusError: Error {
    let status: OSStatus
}

final class ClaudeService {
    private static let knownCLIPaths = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]
    private static let refreshCoordinator = ManagedCredentialRefreshCoordinator()
    private static let oauthTokenURL = ClaudeOAuthFlow.tokenURL
    private static let oauthClientID = ClaudeOAuthFlow.clientID

    func locateCLI() throws -> URL {
        let fileManager = FileManager.default
        for candidate in Self.knownCLIPaths {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { path -> String? in
            FileManager.default.isExecutableFile(atPath: path) ? path : nil
        } ?? "/bin/zsh"
        let result = try run(executable: URL(fileURLWithPath: shell), arguments: ["-l", "-c", "command -v claude"])
        let path = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard result.status == 0, !path.isEmpty, fileManager.isExecutableFile(atPath: path) else {
            throw ClaudeServiceError.cliNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private func copyData(for query: [CFString: Any]) throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainStatusError(status: status) }
        return data
    }

    func managedAccessToken() throws -> String {
        try readManagedCredential().accessToken
    }

    func loginAndCapture(cliURL: URL, session: URLSession = .shared) async throws -> ManagedClaudeCredential {
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw ClaudeServiceError.cliNotFound
        }

        do {
            let listener = try ClaudeOAuthLoopback()
            let verifier = ClaudeOAuthFlow.randomURLSafeString()
            let state = ClaudeOAuthFlow.randomURLSafeString()
            let authorizeURL = try ClaudeOAuthFlow.authorizeURL(
                codeChallenge: ClaudeOAuthFlow.codeChallenge(for: verifier),
                state: state,
                redirectURI: listener.redirectURI
            )
            let opened = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
            guard opened else { throw ClaudeServiceError.loginCaptureFailed }

            let callback = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try listener.wait(expectedState: state, timeout: 300)
                }.value
            } onCancel: {
                listener.stop()
            }
            guard callback.error == nil,
                  callback.state == state,
                  let code = callback.code,
                  !code.isEmpty else {
                throw ClaudeServiceError.loginCaptureFailed
            }

            let request = try ClaudeOAuthFlow.makeTokenRequest(
                code: code,
                verifier: verifier,
                state: state,
                redirectURI: listener.redirectURI
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ClaudeServiceError.loginCaptureFailed
            }
            let credential = try ClaudeOAuthFlow.parseTokenResponse(data)
            try storeManagedCredential(credential)
            return credential
        } catch let error as ClaudeServiceError {
            throw error
        } catch {
            throw ClaudeServiceError.loginCaptureFailed
        }
    }

    func fetchManagedQuota(session: URLSession = .shared) async throws -> QuotaWindow {
        var credential = try await refreshedManagedCredentialIfNeeded(session: session, force: false)
        do {
            return try await fetchQuota(accessToken: credential.accessToken, session: session)
        } catch let error as ClaudeServiceError where error == .quotaUnauthorized {
            credential = try await refreshedManagedCredentialIfNeeded(session: session, force: true)
            return try await fetchQuota(accessToken: credential.accessToken, session: session)
        }
    }

    private func readManagedCredential() throws -> ManagedClaudeCredential {
        do {
            let data = try copyData(for: ClaudeCredentialQueries.cacheRead())
            return try Self.parseManagedCredential(from: data)
        } catch let error as KeychainStatusError where error.status == errSecItemNotFound {
            throw ClaudeServiceError.managedCredentialsUnavailable
        } catch is KeychainStatusError {
            throw ClaudeServiceError.credentialsUnavailable
        }
    }

    private func storeManagedCredential(_ credential: ManagedClaudeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        try storeManagedCredentialData(data)
    }

    private func storeManagedCredentialData(_ data: Data) throws {
        let status = SecItemUpdate(
            ClaudeCredentialQueries.cacheUpdateQuery() as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            let payload = ClaudeCredentialQueries.cacheAddPayload(data: data)
            let addStatus = SecItemAdd(payload as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudeServiceError.credentialsUnavailable }
        } else if status != errSecSuccess {
            throw ClaudeServiceError.credentialsUnavailable
        }
    }

    private func refreshedManagedCredentialIfNeeded(session: URLSession, force: Bool) async throws -> ManagedClaudeCredential {
        let credential = try readManagedCredential()
        guard force || credential.needsRefresh() else { return credential }
        diagnosticLog("oauth.refresh_requested", [
            "operation_id": DiagnosticContext.operationID ?? "none",
            "reason": force ? "forced_after_unauthorized" : "expiry_window",
            "previous_expires_at": diagnosticDate(credential.expiresAt)
        ])
        do {
            let refreshed = try await Self.refreshCoordinator.run {
                try await Self.refreshManagedCredential(credential, session: session)
            }
            try storeManagedCredential(refreshed)
            diagnosticLog("oauth.refresh_completed", [
                "operation_id": DiagnosticContext.operationID ?? "none",
                "outcome": "success",
                "new_expires_at": diagnosticDate(refreshed.expiresAt),
                "refresh_rotated": refreshed.refreshToken == credential.refreshToken ? "false" : "true"
            ])
            return refreshed
        } catch {
            diagnosticLog("oauth.refresh_completed", [
                "operation_id": DiagnosticContext.operationID ?? "none",
                "outcome": "failed",
                "error_code": Self.diagnosticErrorCode(error)
            ])
            throw error
        }
    }

    private static func refreshManagedCredential(_ credential: ManagedClaudeCredential, session: URLSession) async throws -> ManagedClaudeCredential {
        let request = makeRefreshRequest(refreshToken: credential.refreshToken)
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            diagnosticLog("oauth.refresh_http", [
                "operation_id": DiagnosticContext.operationID ?? "none",
                "outcome": "network_error",
                "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            ])
            throw ClaudeServiceError.oauthRefreshFailed
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        diagnosticLog("oauth.refresh_http", [
            "operation_id": DiagnosticContext.operationID ?? "none",
            "outcome": statusCode == 200 ? "success" : "http_error",
            "status_code": statusCode.map(String.init) ?? "none",
            "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        ])
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let refreshed = mergeRefreshResponse(data, into: credential) else {
            throw ClaudeServiceError.oauthRefreshFailed
        }
        return refreshed
    }

    static func makeRefreshRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: oauthTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
            "scope": ClaudeOAuthFlow.scope
        ])
        return request
    }

    static func mergeRefreshResponse(_ data: Data, into credential: ManagedClaudeCredential, now: Date = Date()) -> ManagedClaudeCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty else { return nil }
        let refreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? credential.refreshToken
        let expiresAtMilliseconds = (object["expires_in"] as? NSNumber).map {
            Int64(now.timeIntervalSince1970 * 1_000) + Int64($0.doubleValue * 1_000)
        } ?? credential.expiresAtMilliseconds
        let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? credential.scopes
        return ManagedClaudeCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAtMilliseconds: expiresAtMilliseconds, scopes: scopes)
    }

    static func parseManagedCredential(from data: Data) throws -> ManagedClaudeCredential {
        if let cached = try? JSONDecoder().decode(ManagedClaudeCredential.self, from: data) {
            return cached
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw ClaudeServiceError.managedCredentialsUnavailable
        }
        let expiresAtMilliseconds: Int64?
        if let value = oauth["expiresAt"] as? NSNumber {
            let raw = value.int64Value
            expiresAtMilliseconds = raw > 10_000_000_000 ? raw : raw * 1_000
        } else {
            expiresAtMilliseconds = nil
        }
        let scopes = oauth["scopes"] as? [String] ?? []
        return ManagedClaudeCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAtMilliseconds: expiresAtMilliseconds, scopes: scopes)
    }

    func fetchQuota(accessToken: String, session: URLSession = .shared) async throws -> QuotaWindow {
        let requestID = UUID().uuidString
        let operationID = DiagnosticContext.operationID ?? requestID
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: ClaudeUsageAdapter.makeRequest(accessToken: accessToken)
            )
        } catch {
            diagnosticLog("quota.http_result", [
                "request_id": requestID,
                "operation_id": operationID,
                "outcome": "network_error",
                "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            ])
            throw ClaudeServiceError.quotaUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            diagnosticLog("quota.http_result", [
                "request_id": requestID,
                "operation_id": operationID,
                "outcome": "invalid_response",
                "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            ])
            throw ClaudeServiceError.quotaUnavailable
        }
        let httpMetadata = [
            "request_id": requestID,
            "operation_id": operationID,
            "status_code": "\(http.statusCode)",
            "outcome": Self.quotaHTTPOutcome(http.statusCode),
            "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
            "response_bytes": "\(data.count)",
            "response_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ]
        diagnosticLog("quota.http_result", httpMetadata)
        guard (200...299).contains(http.statusCode) else {
            throw Self.quotaError(for: http.statusCode)
        }
        var shapeMetadata = ClaudeUsageAdapter.diagnosticMetadata(data)
        shapeMetadata["request_id"] = requestID
        shapeMetadata["operation_id"] = operationID
        do {
            let quota = try ClaudeUsageAdapter.parseQuotaWindow(data)
            shapeMetadata["parse"] = "success"
            shapeMetadata["active"] = quota.active ? "true" : "false"
            shapeMetadata["used_percent"] = quota.usedPercent.map { String($0) } ?? "none"
            shapeMetadata["resets_at"] = diagnosticDate(quota.resetsAt)
            diagnosticLog("quota.five_hour_shape", shapeMetadata)
            return quota
        } catch {
            shapeMetadata["parse"] = "failed"
            diagnosticLog("quota.five_hour_shape", shapeMetadata)
            throw error
        }
    }

    static func quotaError(for statusCode: Int) -> ClaudeServiceError {
        switch statusCode {
        case 401, 403: return .quotaUnauthorized
        case 429: return .quotaRateLimited
        default: return .quotaUnavailable
        }
    }

    private static func quotaHTTPOutcome(_ statusCode: Int) -> String {
        switch statusCode {
        case 200...299: return "success"
        case 401, 403: return "unauthorized"
        case 429: return "rate_limited"
        default: return "unavailable"
        }
    }

    static func diagnosticErrorCode(_ error: Error) -> String {
        guard let error = error as? ClaudeServiceError else { return "unexpected" }
        switch error {
        case .cliNotFound: return "cli_not_found"
        case .credentialsUnavailable: return "keychain_unavailable"
        case .managedCredentialsUnavailable: return "managed_credentials_missing"
        case .loginCaptureFailed: return "oauth_login_failed"
        case .oauthLoginTimedOut: return "oauth_login_timeout"
        case .oauthRefreshFailed: return "oauth_refresh_failed"
        case .invalidUsageResponse: return "usage_parse_failed"
        case .quotaUnauthorized: return "usage_unauthorized"
        case .quotaRateLimited: return "usage_rate_limited"
        case .quotaUnavailable: return "usage_unavailable"
        case .warmupNotStarted: return "warmup_not_started"
        case .warmupTimedOut: return "warmup_timeout"
        case .warmupFailed: return "warmup_marker_missing"
        }
    }

    /// 이 메서드는 실제 워밍 실행 경로다. 테스트에서는 호출하지 않는다.
    func performWarmup(command: ClaudeWarmupCommand, timeout: TimeInterval = 30) throws {
        let diagnosticStartedAt = Date()
        var diagnosticOutcome = "setup_failed"
        var diagnosticProcess: Process?
        var diagnosticProcessStarted = false
        var requiredForcedStop = false
        defer {
            var metadata = [
                "outcome": diagnosticOutcome,
                "operation_id": DiagnosticContext.operationID ?? "none",
                "elapsed_ms": "\(Int(Date().timeIntervalSince(diagnosticStartedAt) * 1_000))",
                "forced_termination": requiredForcedStop ? "true" : "false"
            ]
            if let process = diagnosticProcess {
                metadata["pid"] = "\(process.processIdentifier)"
                if diagnosticProcessStarted, !process.isRunning {
                    metadata["exit_status"] = "\(process.terminationStatus)"
                }
            }
            diagnosticLogCritical("warmup.process_finished", metadata)
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            diagnosticOutcome = "pty_open_failed"
            throw ClaudeServiceError.warmupNotStarted
        }
        defer {
            if masterFD >= 0 { close(masterFD) }
            if slaveFD >= 0 { close(slaveFD) }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionWarmer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            diagnosticOutcome = "temp_directory_failed"
            throw ClaudeServiceError.warmupNotStarted
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let process = Process()
        diagnosticProcess = process
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = temporaryDirectory
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        var processStarted = false
        defer {
            if processStarted { Self.stopProcess(process) }
        }
        do {
            try process.run()
        } catch {
            diagnosticOutcome = "spawn_failed"
            throw ClaudeServiceError.warmupNotStarted
        }
        processStarted = true
        diagnosticProcessStarted = true
        diagnosticOutcome = "running"
        diagnosticLog("warmup.process_started", [
            "pid": "\(process.processIdentifier)",
            "operation_id": DiagnosticContext.operationID ?? "none",
            "timeout_ms": "\(Int(timeout * 1_000))"
        ])
        close(slaveFD)
        slaveFD = -1

        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        do {
            try writeToPTY("\(command.prompt)\r", fd: masterFD)
        } catch {
            diagnosticOutcome = "pty_write_failed"
            requiredForcedStop = process.isRunning
            throw error
        }
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var receivedMarker = false
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                if String(data: output, encoding: .utf8)?.contains(ClaudeWarmupCommand.successMarker) == true {
                    receivedMarker = true
                    try? writeToPTY("/exit\r", fd: masterFD)
                    break
                }
            } else if !process.isRunning {
                break
            }
            usleep(50_000)
        }
        if receivedMarker {
            let exitDeadline = min(deadline, Date().addingTimeInterval(0.75))
            while process.isRunning && Date() < exitDeadline { usleep(25_000) }
        }
        guard receivedMarker else {
            requiredForcedStop = process.isRunning
            if Date() >= deadline {
                diagnosticOutcome = "timeout"
                throw ClaudeServiceError.warmupTimedOut
            }
            diagnosticOutcome = "exit_without_marker"
            throw ClaudeServiceError.warmupFailed
        }
        diagnosticOutcome = "marker_received"
        requiredForcedStop = process.isRunning
    }

    private func run(executable: URL, arguments: [String]) throws -> (stdout: Data, status: Int32) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    private func writeToPTY(_ string: String, fd: Int32) throws {
        let bytes = Array(string.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { throw ClaudeServiceError.warmupFailed }
    }

    private static func stopProcess(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminateDeadline { usleep(25_000) }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline { usleep(25_000) }
        }
        if !process.isRunning {
            process.waitUntilExit()
        }
    }
}
