import Foundation
import Security
import LocalAuthentication
import Darwin

enum ClaudeServiceError: LocalizedError, Equatable {
    case cliNotFound
    case invalidAuthStatus
    case apiBillingEnvironment
    case credentialsUnavailable
    case credentialsRequireManualRefresh
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
        case .invalidAuthStatus: return "claude.ai 구독 인증 상태를 확인할 수 없습니다."
        case .apiBillingEnvironment: return "API 과금 환경에서는 워밍을 실행할 수 없습니다."
        case .credentialsUnavailable: return "Claude Code 인증 정보를 Keychain에서 읽을 수 없습니다."
        case .credentialsRequireManualRefresh: return "Mac 잠금을 해제한 뒤 메뉴바에서 새로고침해 Claude Code 인증을 승인하세요."
        case .invalidUsageResponse: return "사용량 응답 형식이 올바르지 않습니다."
        case .quotaUnauthorized: return "Claude 인증이 만료됐을 수 있습니다. Mac 잠금을 해제한 뒤 새로고침해 주세요."
        case .quotaRateLimited: return "Claude 사용량 조회 요청이 제한되었습니다."
        case .quotaUnavailable: return "Claude 사용량 조회 서비스를 사용할 수 없습니다."
        case .warmupNotStarted: return "Claude 워밍 프로세스를 시작하지 못했습니다."
        case .warmupTimedOut: return "워밍 호출 시간이 초과되었습니다."
        case .warmupFailed: return "워밍 호출이 성공 마커를 반환하지 않았습니다."
        }
    }
}

struct ClaudeAuthStatus: Equatable {
    let loggedIn: Bool
    let authMethod: String
    let apiProvider: String
    let subscriptionType: String

    static func parse(_ data: Data) throws -> ClaudeAuthStatus {
        struct Payload: Decodable {
            let loggedIn: Bool
            let authMethod: String?
            let apiProvider: String?
            let subscriptionType: String?
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ClaudeServiceError.invalidAuthStatus
        }
        guard payload.loggedIn,
              payload.authMethod == "claude.ai",
              payload.apiProvider == "firstParty",
              let subscriptionType = payload.subscriptionType,
              !subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if payload.apiProvider != nil, payload.apiProvider != "firstParty" {
                throw ClaudeServiceError.apiBillingEnvironment
            }
            throw ClaudeServiceError.invalidAuthStatus
        }
        return ClaudeAuthStatus(
            loggedIn: true,
            authMethod: "claude.ai",
            apiProvider: "firstParty",
            subscriptionType: subscriptionType
        )
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

    static func make(executableURL: URL, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeWarmupCommand {
        var environment = inheritedEnvironment
        ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS"].forEach {
            environment.removeValue(forKey: $0)
        }
        environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
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
    static let cacheAccount = "claude-access-token"

    static func source(allowsInteraction: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: sourceService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if !allowsInteraction {
            query[kSecUseAuthenticationContext] = nonInteractiveContext()
        }
        return query
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

    static func cacheUpdateAttributes(token: String) -> [CFString: Any] {
        [kSecValueData: ClaudeService.cachePayload(for: token)]
    }

    static func cacheAddPayload(token: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cacheService,
            kSecAttrAccount: cacheAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: ClaudeService.cachePayload(for: token)
        ]
    }

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
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

    func checkAuth(cliURL: URL) throws -> ClaudeAuthStatus {
        let result = try run(executable: cliURL, arguments: ["auth", "status"])
        guard result.status == 0 else { throw ClaudeServiceError.invalidAuthStatus }
        return try ClaudeAuthStatus.parse(result.stdout)
    }

    /// 자동 실행은 인증 UI를 띄우지 않고 source Keychain 뒤 앱 전용 cache를 조회한다.
    func readAccessToken(allowsInteraction: Bool) throws -> String {
        if allowsInteraction {
            do {
                let token = try Self.parseAccessToken(
                    from: try copyData(for: ClaudeCredentialQueries.source(allowsInteraction: true))
                )
                try storeCachedAccessToken(token)
                return token
            } catch let error as KeychainStatusError {
                throw Self.manualCredentialError(for: error.status)
            }
        }

        do {
            let token = try Self.parseAccessToken(from: try copyData(for: ClaudeCredentialQueries.source(allowsInteraction: false)))
            try storeCachedAccessToken(token)
            return token
        } catch is KeychainStatusError {
            return try readCachedAccessTokenOrRequireRefresh()
        } catch {
            throw ClaudeServiceError.credentialsUnavailable
        }
    }

    private func readCachedAccessTokenOrRequireRefresh() throws -> String {
        do {
            return try Self.parseCachedAccessToken(try copyData(for: ClaudeCredentialQueries.cacheRead()))
        } catch {
            throw ClaudeServiceError.credentialsRequireManualRefresh
        }
    }

    private func storeCachedAccessToken(_ token: String) throws {
        let status = SecItemUpdate(
            ClaudeCredentialQueries.cacheUpdateQuery() as CFDictionary,
            ClaudeCredentialQueries.cacheUpdateAttributes(token: token) as CFDictionary
        )
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(ClaudeCredentialQueries.cacheAddPayload(token: token) as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudeServiceError.credentialsUnavailable }
        } else if status != errSecSuccess {
            throw ClaudeServiceError.credentialsUnavailable
        }
    }

    private func copyData(for query: [CFString: Any]) throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainStatusError(status: status) }
        return data
    }

    static func parseAccessToken(from data: Data) throws -> String {
        struct Credentials: Decodable {
            struct ClaudeAIOAuth: Decodable { let accessToken: String? }
            let accessToken: String?
            let claudeAiOauth: ClaudeAIOAuth?
        }
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              let accessToken = credentials.accessToken ?? credentials.claudeAiOauth?.accessToken,
              !accessToken.isEmpty else {
            throw ClaudeServiceError.credentialsUnavailable
        }
        return accessToken
    }

    static func manualCredentialError(for status: OSStatus) -> ClaudeServiceError {
        switch status {
        case errSecItemNotFound:
            return .credentialsUnavailable
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .credentialsRequireManualRefresh
        default:
            return .credentialsUnavailable
        }
    }

    static func cachePayload(for accessToken: String) -> Data {
        Data(accessToken.utf8)
    }

    static func parseCachedAccessToken(_ data: Data) throws -> String {
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw ClaudeServiceError.credentialsRequireManualRefresh
        }
        return token
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

    private static func run(executable: URL, arguments: [String]) throws -> (stdout: Data, status: Int32) {
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

    private func run(executable: URL, arguments: [String]) throws -> (stdout: Data, status: Int32) {
        try Self.run(executable: executable, arguments: arguments)
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
