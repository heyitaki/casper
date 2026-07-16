@testable import CMUXDebugLog
import XCTest

final class CappedLogWriterTests: XCTestCase {
    private var tempDir: URL!
    private var logPath: String!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capped-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logPath = tempDir.appendingPathComponent("test.log").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func append(_ text: String, maxBytes: Int = 1024, tailKeepBytes: Int = 256) {
        CappedLogWriter.append(
            Data(text.utf8),
            toFileAtPath: logPath,
            maxBytes: maxBytes,
            tailKeepBytes: tailKeepBytes
        )
    }

    private func contents() throws -> String {
        try String(contentsOfFile: logPath, encoding: .utf8)
    }

    func testDefaultCapIs256MB() {
        XCTAssertEqual(CappedLogWriter.defaultMaxBytes, 256 * 1024 * 1024)
    }

    func testCreatesFileWhenMissing() throws {
        append("hello\n")
        XCTAssertEqual(try contents(), "hello\n")
    }

    func testAppendsBelowCapWithoutTrimming() throws {
        append("one\n")
        append("two\n")
        XCTAssertEqual(try contents(), "one\ntwo\n")
    }

    func testTrimsWhenAppendWouldCrossCap() throws {
        for i in 0..<200 {
            append(String(format: "line-%03d\n", i))
        }
        let text = try contents()
        XCTAssertTrue(text.hasPrefix("--- cmux debug log auto-trimmed from "))
        XCTAssertTrue(text.hasSuffix("line-199\n"))
        XCTAssertFalse(text.contains("line-000"))
        XCTAssertLessThanOrEqual(text.utf8.count, 1024)
    }

    func testTrimmedTailStartsAtLineBoundary() throws {
        for i in 0..<200 {
            append(String(format: "line-%03d\n", i))
        }
        let lines = try contents().split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.dropFirst() where !line.isEmpty {
            XCTAssertTrue(line.hasPrefix("line-"), "partial line survived trim: \(line)")
            XCTAssertEqual(line.count, 8)
        }
    }

    func testTrimPreservesInodeAndWritesExactMarker() throws {
        for i in 0..<100 {
            append(String(format: "line-%03d\n", i))
        }
        let before = try FileManager.default
            .attributesOfItem(atPath: logPath)[.systemFileNumber] as? UInt
        append(String(repeating: "x", count: 200) + "\n")
        let after = try FileManager.default
            .attributesOfItem(atPath: logPath)[.systemFileNumber] as? UInt
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after, "trim must reuse the same inode so tail -f keeps working")
        XCTAssertTrue(try contents().hasPrefix("--- cmux debug log auto-trimmed from 900 bytes ---\n"))
    }

    func testAppendsContinueAfterTrim() throws {
        for i in 0..<150 {
            append(String(format: "line-%03d\n", i))
        }
        append("after-trim\n")
        XCTAssertTrue(try contents().hasSuffix("after-trim\n"))
    }

    func testResolvedMaxBytesParsesMegabytes() {
        XCTAssertEqual(
            CappedLogWriter.resolvedMaxBytes(environment: ["CMUX_DEBUG_LOG_MAX_MB": "512"]),
            512 * 1024 * 1024
        )
        XCTAssertEqual(
            CappedLogWriter.resolvedMaxBytes(environment: ["CMUX_DEBUG_LOG_MAX_MB": "1"]),
            1024 * 1024
        )
    }

    func testResolvedMaxBytesFallsBackToDefault() {
        XCTAssertEqual(
            CappedLogWriter.resolvedMaxBytes(environment: [:]),
            CappedLogWriter.defaultMaxBytes
        )
        XCTAssertEqual(
            CappedLogWriter.resolvedMaxBytes(environment: ["CMUX_DEBUG_LOG_MAX_MB": "abc"]),
            CappedLogWriter.defaultMaxBytes
        )
        XCTAssertEqual(
            CappedLogWriter.resolvedMaxBytes(environment: ["CMUX_DEBUG_LOG_MAX_MB": "0"]),
            CappedLogWriter.defaultMaxBytes
        )
        XCTAssertEqual(
            CappedLogWriter.resolvedMaxBytes(environment: ["CMUX_DEBUG_LOG_MAX_MB": "-5"]),
            CappedLogWriter.defaultMaxBytes
        )
    }

    func testTailKeepBytesScalesWithCap() {
        XCTAssertEqual(CappedLogWriter.tailKeepBytes(forMaxBytes: 256 * 1024 * 1024), 64 * 1024 * 1024)
        XCTAssertEqual(CappedLogWriter.tailKeepBytes(forMaxBytes: 512 * 1024 * 1024), 64 * 1024 * 1024)
        XCTAssertEqual(CappedLogWriter.tailKeepBytes(forMaxBytes: 8 * 1024 * 1024), 2 * 1024 * 1024)
        XCTAssertEqual(CappedLogWriter.tailKeepBytes(forMaxBytes: 2 * 1024 * 1024), 1024 * 1024)
    }
}
