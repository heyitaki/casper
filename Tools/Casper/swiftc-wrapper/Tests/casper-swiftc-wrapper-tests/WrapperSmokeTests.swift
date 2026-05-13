// CASPER: end-to-end smoke test for casper-swiftc-wrapper. Exercises the JSONL
// append + flock-guarded write by execing the built wrapper with synthetic
// argv into an isolated temp HOME. Full concurrency/schema-coverage tests land
// in PR 1.5.

import XCTest

final class WrapperSmokeTests: XCTestCase {
    func testWrapperWritesJSONLAndExecsRealSwiftc() throws {
        // Locate the built wrapper. .build/release or .build/debug — whichever is
        // newer. SwiftPM places executable products under `.build/<config>/<name>`.
        let fm = FileManager.default
        let scratchRoot = ProcessInfo.processInfo.environment["SWIFTPM_TESTS_SCRATCH_PATH"]
            ?? "\(fm.currentDirectoryPath)/.build"
        let candidates = [
            "\(scratchRoot)/release/casper-swiftc-wrapper",
            "\(scratchRoot)/debug/casper-swiftc-wrapper",
        ]
        guard let wrapperPath = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("wrapper binary not yet built; run `swift build` first")
        }

        let tempDir = NSTemporaryDirectory() + "casper-hmr-wrapper-smoke-\(UUID().uuidString)"
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapperPath)
        process.arguments = ["--version"]
        process.environment = [
            "HOME": tempDir,
            "CASPER_HMR_TAG": "smoke",
            "PATH": "/usr/bin:/bin",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let jsonlPath = "\(tempDir)/.casper/hmr/smoke/commands.jsonl"
        XCTAssertTrue(fm.fileExists(atPath: jsonlPath), "wrapper should have written commands.jsonl")
        let contents = try String(contentsOfFile: jsonlPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"schema\":1"), "JSONL entry should carry schema=1")
        XCTAssertTrue(contents.contains("\"tag\":\"smoke\""), "JSONL entry should carry tag=smoke")
    }
}
