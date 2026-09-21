import Darwin
import Foundation

enum InstallationPolicy {
    static let bundleIdentifier = "com.sharknia.ClaudeSessionWarmer"
    static let applicationURL = URL(fileURLWithPath: "/Applications/ClaudeSessionWarmer.app")
    static let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(bundleIdentifier)", isDirectory: true)

    static func isCanonicalApp(_ url: URL) -> Bool {
        // 복사본과 심볼릭 링크로 실행한 앱이 로그인 항목의 주체가 되지 않게 한다.
        url.standardizedFileURL == applicationURL
            && url.resolvingSymlinksInPath() == applicationURL
    }
}

/// 파일은 삭제하지 않는다. 앱 종료 시 descriptor를 닫으면 OS가 잠금을 해제한다.
final class ExecutionOwnership {
    enum Failure: Error { case alreadyRunning, unavailable(Int32) }
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("execution.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw Failure.unavailable(code)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

struct LegacyAppProcess: Equatable {
    let pid: Int32
    let path: String

    /// Launch Services에 등록되지 않은 실행 파일도 확인한다. 다른 사용자의 프로세스는 제외한다.
    static func running() -> [LegacyAppProcess] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), capacity)).compactMap { pid in
            guard pid > 0, pid != getpid() else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
                  info.pbi_uid == getuid() else { return nil }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let executable = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            guard executable.deletingLastPathComponent().lastPathComponent == "MacOS" else { return nil }
            let bundleURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard let bundle = Bundle(url: bundleURL),
                  bundle.bundleIdentifier == InstallationPolicy.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CSWExecutionProtocolVersion") as? Int != 1 else { return nil }
            return LegacyAppProcess(pid: pid, path: bundleURL.path)
        }
    }
}
