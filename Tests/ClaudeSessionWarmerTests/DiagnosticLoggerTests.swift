import Foundation
import XCTest
@testable import ClaudeSessionWarmer

final class DiagnosticLoggerTests: XCTestCase {
    func testAppendWritesParseableRedactedJSONLWithPrivatePermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directoryURL: directory, launchID: "test-launch")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        logger.logAndFlush(
            event: "warmup.completed",
            metadata: [
                "status": "succeeded",
                "access_token": "must-not-be-written",
                "authorization_header": "must-not-be-written",
                "oauth_state": "must-not-be-written",
                "prompt": "must-not-be-written"
            ],
            at: timestamp
        )

        let file = directory.appendingPathComponent("events.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "warmup.completed")
        XCTAssertEqual(object["launch_id"] as? String, "test-launch")
        XCTAssertEqual((object["sequence"] as? NSNumber)?.uint64Value, 1)
        XCTAssertNotNil(object["timestamp"] as? String)
        let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
        XCTAssertEqual(metadata, ["status": "succeeded"])
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("must-not-be-written"))

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testRotationKeepsOnlyCurrentAndOnePreviousFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directoryURL: directory, maximumFileSize: 220)
        let metadata = ["status": String(repeating: "x", count: 140)]

        logger.logAndFlush(event: "one", metadata: metadata)
        logger.logAndFlush(event: "two", metadata: metadata)
        logger.logAndFlush(event: "three", metadata: metadata)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["events.jsonl", "events.previous.jsonl"])

        let current = try String(
            contentsOf: directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        let previous = try String(
            contentsOf: directory.appendingPathComponent("events.previous.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(current.contains("three"))
        XCTAssertTrue(previous.contains("two"))
        XCTAssertFalse(previous.contains("one"))
    }

    func testNextSuccessfulEntryReportsPriorWriteFailure() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedPath = root.appendingPathComponent("blocked")
        XCTAssertTrue(FileManager.default.createFile(atPath: blockedPath.path, contents: Data()))
        let logger = DiagnosticLogger(directoryURL: blockedPath, launchID: "failure-test")

        logger.logAndFlush(event: "will-fail")
        try FileManager.default.removeItem(at: blockedPath)
        try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: true)
        logger.logAndFlush(event: "recovered")

        let data = try Data(contentsOf: blockedPath.appendingPathComponent("events.jsonl"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
        XCTAssertEqual(metadata["logging_failures_since_previous"], "1")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLoggerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
