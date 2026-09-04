import AppKit
import Foundation
import os

enum DiagnosticContext {
    @TaskLocal static var operationID: String?
}

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private struct Entry: Encodable {
        let timestamp: String
        let launchID: String
        let sequence: UInt64
        let event: String
        let metadata: [String: String]

        enum CodingKeys: String, CodingKey {
            case timestamp
            case launchID = "launch_id"
            case sequence
            case event
            case metadata
        }
    }

    private static let sensitiveKeyFragments = [
        "token",
        "authcode",
        "authorizationcode",
        "authorizationheader",
        "oauthcode",
        "oauthstate",
        "pkce",
        "verifier",
        "codeverifier",
        "prompt",
        "rawresponse",
        "responsebody",
        "password",
        "secret",
        "cookie"
    ]

    private let directoryURL: URL
    private let maximumFileSize: Int
    private let launchID: String
    private let queue = DispatchQueue(label: "com.sharknia.ClaudeSessionWarmer.diagnostics")
    private let fallbackLogger = Logger(
        subsystem: "com.sharknia.ClaudeSessionWarmer",
        category: "diagnostics"
    )
    private var nextSequence: UInt64 = 1
    private var pendingFailureCount: UInt64 = 0

    init(
        directoryURL: URL? = nil,
        maximumFileSize: Int = 2 * 1_024 * 1_024,
        launchID: String = UUID().uuidString
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.maximumFileSize = max(1, maximumFileSize)
        self.launchID = launchID
    }

    func log(event: String, metadata: [String: String] = [:], at date: Date = Date()) {
        queue.async { [self] in
            writeEntry(event: event, metadata: metadata, at: date)
        }
    }

    func logAndFlush(event: String, metadata: [String: String] = [:], at date: Date = Date()) {
        queue.sync { [self] in
            writeEntry(event: event, metadata: metadata, at: date)
        }
    }

    func flush() {
        queue.sync {}
    }

    static func redacted(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata.prefix(32) {
            let normalizedKey = key.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !sensitiveKeyFragments.contains(where: normalizedKey.contains) else { continue }
            result[singleLine(key, limit: 64)] = singleLine(value, limit: 512)
        }
        return result
    }

    private static func defaultDirectoryURL() -> URL {
        if ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("test") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClaudeSessionWarmerTests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClaudeSessionWarmer", isDirectory: true)
    }

    private func writeEntry(event: String, metadata: [String: String], at date: Date) {
        do {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var safeMetadata = Self.redacted(metadata)
            if pendingFailureCount > 0 {
                safeMetadata["logging_failures_since_previous"] = "\(pendingFailureCount)"
            }
            let entry = Entry(
                timestamp: formatter.string(from: date),
                launchID: launchID,
                sequence: nextSequence,
                event: Self.singleLine(event, limit: 128),
                metadata: safeMetadata
            )
            var line = try JSONEncoder().encode(entry)
            line.append(0x0A)
            try append(line)
            nextSequence += 1
            pendingFailureCount = 0
        } catch {
            pendingFailureCount += 1
            fallbackLogger.error("diagnostic file append failed")
        }
    }

    private func append(_ line: Data) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let currentURL = directoryURL.appendingPathComponent("events.jsonl")
        let previousURL = directoryURL.appendingPathComponent("events.previous.jsonl")
        let currentSize = ((try? fileManager.attributesOfItem(atPath: currentURL.path)[.size]) as? NSNumber)?
            .intValue ?? 0

        if currentSize > 0, currentSize + line.count > maximumFileSize {
            if fileManager.fileExists(atPath: previousURL.path) {
                try fileManager.removeItem(at: previousURL)
            }
            try fileManager.moveItem(at: currentURL, to: previousURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousURL.path)
        }

        if !fileManager.fileExists(atPath: currentURL.path) {
            guard fileManager.createFile(
                atPath: currentURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentURL.path)

        let handle = try FileHandle(forWritingTo: currentURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private static func singleLine(_ value: String, limit: Int) -> String {
        String(value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(limit))
    }
}

func diagnosticLog(_ event: String, _ metadata: [String: String] = [:]) {
    DiagnosticLogger.shared.log(event: event, metadata: metadata)
}

func diagnosticLogCritical(_ event: String, _ metadata: [String: String] = [:]) {
    DiagnosticLogger.shared.logAndFlush(event: event, metadata: metadata)
}

func diagnosticDate(_ date: Date?) -> String {
    guard let date else { return "none" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

final class LifecycleMonitor {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private let heartbeat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    init() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for (name, event, critical) in [
            (NSWorkspace.willSleepNotification, "power.system_sleep", true),
            (NSWorkspace.didWakeNotification, "power.system_wake", false),
            (NSWorkspace.screensDidSleepNotification, "power.display_sleep", false),
            (NSWorkspace.screensDidWakeNotification, "power.display_wake", false)
        ] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                if critical {
                    diagnosticLogCritical(event)
                } else {
                    diagnosticLog(event)
                }
            })
        }

        let distributedCenter = DistributedNotificationCenter.default()
        for (name, event) in [
            (Notification.Name("com.apple.screenIsLocked"), "power.screen_locked"),
            (Notification.Name("com.apple.screenIsUnlocked"), "power.screen_unlocked")
        ] {
            distributedObservers.append(distributedCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                diagnosticLog(event)
            })
        }

        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            diagnosticLogCritical("app.will_terminate")
        })

        heartbeat.schedule(deadline: .now() + .seconds(15 * 60), repeating: .seconds(15 * 60))
        heartbeat.setEventHandler {
            diagnosticLog("app.heartbeat", ["pid": "\(ProcessInfo.processInfo.processIdentifier)"])
        }
        heartbeat.resume()
    }

    deinit {
        heartbeat.cancel()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributedCenter.removeObserver)
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
