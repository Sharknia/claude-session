import XCTest
import LocalAuthentication
@testable import ClaudeSessionWarmer

final class ClaudeServiceTests: XCTestCase {
    func testAuthStatusAcceptsClaudeAISubscription() throws {
        let data = Data("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"pro\"}".utf8)
        XCTAssertEqual(try ClaudeAuthStatus.parse(data).subscriptionType, "pro")
    }

    func testAuthStatusRejectsAPIProvider() {
        let data = Data("{\"loggedIn\":true,\"authMethod\":\"apiKey\",\"apiProvider\":\"api\",\"subscriptionType\":\"\"}".utf8)
        XCTAssertThrowsError(try ClaudeAuthStatus.parse(data)) { error in
            XCTAssertEqual(error as? ClaudeServiceError, .apiBillingEnvironment)
        }
    }

    func testCheckAuthParsesJSONFromFakeExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try "#!/bin/sh\n[ \"$1\" = auth ] && [ \"$2\" = status ] && [ \"$#\" = 2 ] || exit 44\necho '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"team\"}'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(try ClaudeService().checkAuth(cliURL: executable).subscriptionType, "team")
    }

    func testUsageRequestUsesOAuthBetaHeader() {
        let request = ClaudeUsageAdapter.makeRequest(accessToken: "not-a-real-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-real-token")
    }

    func testCredentialParserAcceptsNestedClaudeAIOAuthToken() throws {
        let data = Data("{\"claudeAiOauth\":{\"accessToken\":\"not-a-real-token\",\"refreshToken\":\"must-not-copy\"}}".utf8)
        XCTAssertEqual(try ClaudeService.parseAccessToken(from: data), "not-a-real-token")
    }

    func testCredentialQueriesUseSourceWithoutUIAndAppOnlyCache() {
        let manualSource = ClaudeCredentialQueries.source(allowsInteraction: true)
        let automaticSource = ClaudeCredentialQueries.source(allowsInteraction: false)
        let cache = ClaudeCredentialQueries.cacheAddPayload(token: "test-access-token")

        XCTAssertEqual(manualSource[kSecAttrService] as? String, ClaudeCredentialQueries.sourceService)
        XCTAssertNil(manualSource[kSecUseAuthenticationContext])
        XCTAssertTrue((automaticSource[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
        XCTAssertEqual(cache[kSecAttrService] as? String, ClaudeCredentialQueries.cacheService)
        XCTAssertEqual(cache[kSecAttrAccount] as? String, ClaudeCredentialQueries.cacheAccount)
        XCTAssertEqual(cache[kSecAttrAccessible] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testManualCredentialErrorsUseUserFacingCategories() {
        XCTAssertEqual(
            ClaudeService.manualCredentialError(for: errSecItemNotFound),
            .credentialsUnavailable
        )
        XCTAssertEqual(
            ClaudeService.manualCredentialError(for: errSecUserCanceled),
            .credentialsRequireManualRefresh
        )
        XCTAssertEqual(
            ClaudeService.manualCredentialError(for: errSecAuthFailed),
            .credentialsRequireManualRefresh
        )
    }

    func testCachePayloadContainsOnlyAccessToken() throws {
        let payload = ClaudeService.cachePayload(for: "test-access-token")
        XCTAssertEqual(try ClaudeService.parseCachedAccessToken(payload), "test-access-token")
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("refresh"))
        XCTAssertThrowsError(try ClaudeService.parseCachedAccessToken(Data())) { error in
            XCTAssertEqual(error as? ClaudeServiceError, .credentialsRequireManualRefresh)
        }
    }

    func testQuotaHTTPStatusErrorsAreDistinguished() {
        XCTAssertEqual(ClaudeService.quotaError(for: 401), .quotaUnauthorized)
        XCTAssertEqual(ClaudeService.quotaError(for: 403), .quotaUnauthorized)
        XCTAssertEqual(ClaudeService.quotaError(for: 429), .quotaRateLimited)
        XCTAssertEqual(ClaudeService.quotaError(for: 500), .quotaUnavailable)
    }

    func testUsageAdapterAcceptsNestedFiveHourWindow() throws {
        let data = Data("{\"rate_limits\":{\"five_hour\":{\"utilization\":42.5,\"resets_at\":\"2026-09-04T12:00:00Z\"}}}".utf8)
        let window = try ClaudeUsageAdapter.parseQuotaWindow(data)
        XCTAssertTrue(window.active)
        XCTAssertEqual(window.usedPercent, 42.5)
        XCTAssertNotNil(window.resetsAt)
    }

    func testUsageAdapterAcceptsObservedClaudeResponseShape() throws {
        let data = Data("""
        {"five_hour":{"utilization":23.0,"resets_at":"2026-09-04T05:20:00.527180+00:00","limit_dollars":null}}
        """.utf8)

        let window = try ClaudeUsageAdapter.parseQuotaWindow(data)

        XCTAssertTrue(window.active)
        XCTAssertEqual(window.usedPercent, 23.0)
        XCTAssertNotNil(window.resetsAt)
    }

    func testUsageAdapterRejectsOutOfRangeUtilization() {
        let data = Data("{\"five_hour\":{\"utilization\":101,\"resets_at\":\"2026-09-04T12:00:00Z\"}}".utf8)
        XCTAssertThrowsError(try ClaudeUsageAdapter.parseQuotaWindow(data))
    }

    func testUsageAdapterTreatsNullOrResetlessWindowAsIdle() throws {
        let nullWindow = try ClaudeUsageAdapter.parseQuotaWindow(Data("{\"five_hour\":null}".utf8))
        XCTAssertEqual(nullWindow, QuotaWindow(active: false, usedPercent: nil, resetsAt: nil))
        let resetless = try ClaudeUsageAdapter.parseQuotaWindow(Data("{\"five_hour\":{\"utilization\":0}}".utf8))
        XCTAssertFalse(resetless.active)
        XCTAssertNil(resetless.resetsAt)
    }

    func testWarmupCommandIsPTYSafeAndRemovesAPIKey() {
        let command = ClaudeWarmupCommand.make(
            executableURL: URL(fileURLWithPath: "/tmp/fake-claude"),
            inheritedEnvironment: ["ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret", "CLAUDE_CODE_OAUTH_TOKEN": "secret", "CLAUDE_CODE_USE_FOUNDRY": "1", "PATH": "/usr/bin"]
        )
        XCTAssertEqual(command.arguments, ["--safe-mode", "--tools", "", "--model", "haiku", "--effort", "low"])
        XCTAssertNil(command.environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(command.environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(command.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(command.environment["CLAUDE_CODE_USE_FOUNDRY"])
        XCTAssertEqual(command.environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"], "1")
        XCTAssertFalse(command.prompt.contains(ClaudeWarmupCommand.successMarker))
        XCTAssertFalse(command.arguments.contains("-p"))
        XCTAssertFalse(command.arguments.contains("--bare"))
    }

    func testPTYWarmupRecognizesMarkerFromFakeExecutable() throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        IFS= read -r _
        printf 'CW_WARMUP_OK\\n'
        IFS= read -r _
        """)
        let command = ClaudeWarmupCommand(
            executableURL: executable,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            prompt: "hello"
        )

        XCTAssertNoThrow(try ClaudeService().performWarmup(command: command, timeout: 2))
    }

    func testPTYWarmupTimeoutKillsUnresponsiveProcess() throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        trap '' TERM
        while :; do :; done
        """)
        let command = ClaudeWarmupCommand(
            executableURL: executable,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            prompt: "hello"
        )
        let startedAt = Date()

        XCTAssertThrowsError(try ClaudeService().performWarmup(command: command, timeout: 0.1)) { error in
            XCTAssertEqual(error as? ClaudeServiceError, .warmupTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testPTYWarmupReportsProcessThatNeverStarted() {
        let command = ClaudeWarmupCommand(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist/claude"),
            arguments: [],
            environment: [:],
            prompt: "hello"
        )

        XCTAssertThrowsError(try ClaudeService().performWarmup(command: command, timeout: 0.1)) { error in
            XCTAssertEqual(error as? ClaudeServiceError, .warmupNotStarted)
        }
    }

    private func makeExecutable(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
