import Foundation
import Security
import LocalAuthentication
import CryptoKit
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
    static let sourceService = "Claude Code-credentials"
    static let cacheService = "com.sharknia.ClaudeSessionWarmer.oauth"
    static let cacheAccount = "claude-managed-credential"

    static func source(allowsInteraction: Bool) -> [CFString: Any] {
        source(service: sourceService, allowsInteraction: allowsInteraction)
    }

    static func source(service: String, allowsInteraction: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sourceAccount(),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if !allowsInteraction {
            query[kSecUseAuthenticationContext] = nonInteractiveContext()
        }
        return query
    }

    static func sourceMutation(service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sourceAccount()
        ]
    }

    static func sourceAccount(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemUsername: String = NSUserName()
    ) -> String {
        let candidate = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? systemUsername
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !candidate.isEmpty && candidate.unicodeScalars.allSatisfy(allowed.contains)
            ? candidate
            : "claude-code-user"
    }

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
    static let loginArguments = ["auth", "login", "--claudeai"]
    private static let knownCLIPaths = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]
    private static let refreshCoordinator = ManagedCredentialRefreshCoordinator()
    private static let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

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

    private func copyOptionalData(for query: [CFString: Any]) throws -> Data? {
        do {
            return try copyData(for: query)
        } catch let error as KeychainStatusError where error.status == errSecItemNotFound {
            return nil
        }
    }

    private func restoreLoginKeychain(legacySnapshot: Data?, scopedService: String) throws {
        deleteSourceCredential(service: scopedService)
        if let legacySnapshot {
            try upsertSourceCredential(legacySnapshot, service: ClaudeCredentialQueries.sourceService)
        } else {
            deleteSourceCredential(service: ClaudeCredentialQueries.sourceService)
        }
    }

    private func upsertSourceCredential(_ data: Data, service: String) throws {
        let query = ClaudeCredentialQueries.sourceMutation(service: service)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStatusError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainStatusError(status: status)
        }
    }

    private func deleteSourceCredential(service: String) {
        _ = SecItemDelete(ClaudeCredentialQueries.sourceMutation(service: service) as CFDictionary)
    }

    private func restoreManagedCredential(_ snapshot: Data?) throws {
        if let snapshot {
            try storeManagedCredentialData(snapshot)
        } else {
            _ = SecItemDelete(ClaudeCredentialQueries.cacheUpdateQuery() as CFDictionary)
        }
    }

    private func runInteractiveLogin(cliURL: URL, configDirectory: URL) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw ClaudeServiceError.warmupNotStarted }
        defer {
            if masterFD >= 0 { close(masterFD) }
            if slaveFD >= 0 { close(slaveFD) }
        }
        let process = Process()
        process.executableURL = cliURL
        process.arguments = Self.loginArguments
        process.environment = Self.loginEnvironment(configDirectory: configDirectory)
        process.currentDirectoryURL = configDirectory
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        do { try process.run() } catch { throw ClaudeServiceError.warmupNotStarted }
        close(slaveFD)
        slaveFD = -1
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(masterFD, &buffer, buffer.count) // Drain without retaining browser/login output.
            usleep(50_000)
        }
        guard !process.isRunning else {
            Self.stopProcess(process)
            throw ClaudeServiceError.loginCaptureFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClaudeServiceError.loginCaptureFailed }
    }

    static func loginEnvironment(
        configDirectory: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inheritedEnvironment
        claudeAuthEnvironmentKeys.forEach { environment.removeValue(forKey: $0) }
        environment["CLAUDE_CONFIG_DIR"] = configDirectory.path
        return environment
    }

    static func scopedClaudeService(for configPath: String) -> String {
        let canonical = configPath.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(ClaudeCredentialQueries.sourceService)-\(digest.prefix(8))"
    }

    static func formURLEncoded(_ values: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.sorted().joined(separator: "&")
        return Data(body.utf8)
    }

    func managedAccessToken() throws -> String {
        try readManagedCredential().accessToken
    }

    func loginAndCapture(cliURL: URL) async throws -> ManagedClaudeCredential {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionWarmer-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let canonicalPath = temporaryDirectory.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        let scopedService = Self.scopedClaudeService(for: canonicalPath)
        let legacySnapshot: Data?
        do {
            legacySnapshot = try copyOptionalData(for: ClaudeCredentialQueries.source(allowsInteraction: true))
        } catch is KeychainStatusError {
            throw ClaudeServiceError.loginCaptureFailed
        }
        let managedSnapshot: Data?
        do {
            managedSnapshot = try copyOptionalData(for: ClaudeCredentialQueries.cacheRead())
        } catch is KeychainStatusError {
            throw ClaudeServiceError.credentialsUnavailable
        }
        do {
            try runInteractiveLogin(cliURL: cliURL, configDirectory: temporaryDirectory)
            let scoped = try? copyData(for: ClaudeCredentialQueries.source(service: scopedService, allowsInteraction: true))
            let legacy = try? copyData(for: ClaudeCredentialQueries.source(allowsInteraction: true))
            guard let captured = scoped ?? legacy.flatMap({ $0 == legacySnapshot ? nil : $0 }) else {
                throw ClaudeServiceError.loginCaptureFailed
            }
            let credential = try Self.parseManagedCredential(from: captured)
            try storeManagedCredential(credential)
            try restoreLoginKeychain(legacySnapshot: legacySnapshot, scopedService: scopedService)
            return credential
        } catch {
            try? restoreLoginKeychain(legacySnapshot: legacySnapshot, scopedService: scopedService)
            try? restoreManagedCredential(managedSnapshot)
            throw error
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
        let refreshed = try await Self.refreshCoordinator.run {
            try await Self.refreshManagedCredential(credential, session: session)
        }
        try storeManagedCredential(refreshed)
        return refreshed
    }

    private static func refreshManagedCredential(_ credential: ManagedClaudeCredential, session: URLSession) async throws -> ManagedClaudeCredential {
        let request = makeRefreshRequest(refreshToken: credential.refreshToken)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let refreshed = mergeRefreshResponse(data, into: credential) else {
            throw ClaudeServiceError.oauthRefreshFailed
        }
        return refreshed
    }

    static func makeRefreshRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID
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
        let (data, response) = try await session.data(for: ClaudeUsageAdapter.makeRequest(accessToken: accessToken))
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeServiceError.quotaUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.quotaError(for: http.statusCode)
        }
        return try ClaudeUsageAdapter.parseQuotaWindow(data)
    }

    static func quotaError(for statusCode: Int) -> ClaudeServiceError {
        switch statusCode {
        case 401, 403: return .quotaUnauthorized
        case 429: return .quotaRateLimited
        default: return .quotaUnavailable
        }
    }

    /// 이 메서드는 실제 워밍 실행 경로다. 테스트에서는 호출하지 않는다.
    func performWarmup(command: ClaudeWarmupCommand, timeout: TimeInterval = 30) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw ClaudeServiceError.warmupNotStarted }
        defer {
            if masterFD >= 0 { close(masterFD) }
            if slaveFD >= 0 { close(slaveFD) }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionWarmer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw ClaudeServiceError.warmupNotStarted
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let process = Process()
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
            throw ClaudeServiceError.warmupNotStarted
        }
        processStarted = true
        close(slaveFD)
        slaveFD = -1

        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        try writeToPTY("\(command.prompt)\r", fd: masterFD)
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
            if Date() >= deadline { throw ClaudeServiceError.warmupTimedOut }
            throw ClaudeServiceError.warmupFailed
        }
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
