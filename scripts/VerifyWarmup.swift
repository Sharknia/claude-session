import Foundation

/// 앱과 같은 서명으로 빌드해 실제 Keychain과 서비스 코드를 검증한다.
/// 토큰, 프롬프트, CLI 출력은 기록하지 않는다.
@main
struct VerifyWarmup {
    static func main() async {
        let operationID = UUID().uuidString
        do {
            try await DiagnosticContext.$operationID.withValue(operationID) {
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
