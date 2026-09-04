import XCTest
import LocalAuthentication
@testable import ClaudeSessionWarmer

final class ClaudeServiceTests: XCTestCase {
    func testUsageRequestUsesOAuthBetaHeader() {
        let request = ClaudeUsageAdapter.makeRequest(accessToken: "not-a-real-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-real-token")
    }

    func testCredentialQueriesUseSourceWithoutUIAndAppOnlyCache() {
        let manualSource = ClaudeCredentialQueries.source(allowsInteraction: true)
        let automaticSource = ClaudeCredentialQueries.source(allowsInteraction: false)
        let mutation = ClaudeCredentialQueries.sourceMutation(service: ClaudeCredentialQueries.sourceService)
        let cache = ClaudeCredentialQueries.cacheAddPayload(data: Data("managed".utf8))

        XCTAssertEqual(manualSource[kSecAttrService] as? String, ClaudeCredentialQueries.sourceService)
        XCTAssertEqual(manualSource[kSecAttrAccount] as? String, ClaudeCredentialQueries.sourceAccount())
        XCTAssertNil(manualSource[kSecUseAuthenticationContext])
        XCTAssertTrue((automaticSource[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
        XCTAssertNil(mutation[kSecReturnData])
        XCTAssertNil(mutation[kSecMatchLimit])
        XCTAssertEqual(cache[kSecAttrService] as? String, ClaudeCredentialQueries.cacheService)
        XCTAssertEqual(cache[kSecAttrAccount] as? String, ClaudeCredentialQueries.cacheAccount)
        XCTAssertEqual(cache[kSecAttrAccessible] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(
            ClaudeCredentialQueries.sourceAccount(environment: ["USER": "valid-user"], systemUsername: "ignored"),
            "valid-user"
        )
        XCTAssertEqual(
            ClaudeCredentialQueries.sourceAccount(environment: ["USER": "first@example.com"], systemUsername: "ignored"),
            "claude-code-user"
        )
        XCTAssertEqual(
            ClaudeCredentialQueries.sourceAccount(environment: ["USER": "first last"], systemUsername: "ignored"),
            "claude-code-user"
        )
    }

    func testManagedCredentialParserAndScopedService() throws {
        let data = Data("{\"claudeAiOauth\":{\"accessToken\":\"managed-access\",\"refreshToken\":\"managed-refresh\",\"expiresAt\":1800000000000,\"scopes\":[\"user:inference\"]}}".utf8)
        let credential = try ClaudeService.parseManagedCredential(from: data)
        XCTAssertEqual(credential.accessToken, "managed-access")
        XCTAssertEqual(credential.refreshToken, "managed-refresh")
        XCTAssertEqual(credential.expiresAtMilliseconds, 1_800_000_000_000)
        XCTAssertEqual(credential.scopes, ["user:inference"])
        XCTAssertEqual(try ClaudeService.parseManagedCredential(from: JSONEncoder().encode(credential)), credential)
        XCTAssertEqual(
            ClaudeService.scopedClaudeService(for: "e\u{301}"),
            ClaudeService.scopedClaudeService(for: "é")
        )
        XCTAssertEqual(ClaudeService.loginArguments, ["auth", "login", "--claudeai"])
        let loginEnvironment = ClaudeService.loginEnvironment(
            configDirectory: URL(fileURLWithPath: "/tmp/managed-login"),
            inheritedEnvironment: [
                "PATH": "/usr/bin",
                "ANTHROPIC_API_KEY": "must-strip",
                "CLAUDE_CODE_OAUTH_TOKEN": "must-strip",
                "CLAUDE_CODE_USE_BEDROCK": "1"
            ]
        )
        XCTAssertEqual(loginEnvironment["PATH"], "/usr/bin")
        XCTAssertEqual(loginEnvironment["CLAUDE_CONFIG_DIR"], "/tmp/managed-login")
        XCTAssertNil(loginEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertNil(loginEnvironment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(loginEnvironment["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertFalse(credential.needsRefresh(now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testRefreshRequestAndMergePreserveRotatedCredentialFields() throws {
        let request = ClaudeService.makeRefreshRequest(refreshToken: "refresh-value")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&grant_type=refresh_token&refresh_token=refresh-value")

        let current = ManagedClaudeCredential(accessToken: "old", refreshToken: "old-refresh", expiresAtMilliseconds: nil, scopes: ["old"])
        let response = Data("{\"access_token\":\"new\",\"refresh_token\":\"rotated\",\"expires_in\":3600,\"scope\":\"user:inference user:profile\"}".utf8)
        let merged = try XCTUnwrap(ClaudeService.mergeRefreshResponse(response, into: current, now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(merged.accessToken, "new")
        XCTAssertEqual(merged.refreshToken, "rotated")
        XCTAssertEqual(merged.expiresAtMilliseconds, 4_600_000)
        XCTAssertEqual(merged.scopes, ["user:inference", "user:profile"])
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

        let managedCommand = ClaudeWarmupCommand.make(
            executableURL: URL(fileURLWithPath: "/tmp/fake-claude"),
            oauthToken: "managed-access",
            inheritedEnvironment: ["ANTHROPIC_API_KEY": "secret"]
        )
        XCTAssertEqual(managedCommand.environment["CLAUDE_CODE_OAUTH_TOKEN"], "managed-access")
        XCTAssertNil(managedCommand.environment["ANTHROPIC_API_KEY"])
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
