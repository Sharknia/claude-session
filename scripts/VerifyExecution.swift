import Foundation
import Darwin

@main
struct VerifyExecution {
    static func main() throws {
        let args = CommandLine.arguments
        if args[1] == "legacy" {
            print(LegacyAppProcess.running().map { "\($0.pid):\($0.path)" }.joined(separator: "\n"))
            return
        }
        do {
            let owner = try ExecutionOwnership(directory: URL(fileURLWithPath: args[1]))
            withExtendedLifetime(owner) {
                print("owner")
                fflush(nil)
                if args.count > 2, args[2] == "exec" {
                    let arguments = [strdup("sleep"), strdup("5"), nil]
                    arguments.withUnsafeBufferPointer { _ = execv("/bin/sleep", $0.baseAddress!) }
                    exit(3)
                }
                _ = readLine()
            }
        } catch ExecutionOwnership.Failure.alreadyRunning {
            print("blocked")
            exit(2)
        }
    }
}
