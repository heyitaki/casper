import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Retention policy for `/tmp/cmux-hang-sample-<pid>-<unix>.txt` dumps.
///
/// Without a bound these accumulate forever: each launch behaves fine (~14
/// samples observed), but nothing pruned across launches, so ~20 tagged
/// reloads/day × ~3 MB/sample reached 1.35 GB over five days. The policy is
/// count-based rather than age-based because launch frequency — not elapsed
/// time — is what drives the total. The budget bounds total disk across all
/// instances sharing `/tmp`, not any single instance's own history.
final class MainThreadHangWatchdogRetentionTests: XCTestCase {
    private func path(pid: Int, unix: Int) -> String {
        "/tmp/cmux-hang-sample-\(pid)-\(unix).txt"
    }

    func testPrunesAllButNewestKeepCount() {
        let paths = [
            path(pid: 1, unix: 1_784_000_001),
            path(pid: 1, unix: 1_784_000_005),
            path(pid: 1, unix: 1_784_000_003),
            path(pid: 1, unix: 1_784_000_002),
            path(pid: 1, unix: 1_784_000_004)
        ]
        let pruned = MainThreadHangWatchdog.samplesToPrune(paths: paths, keep: 2)
        XCTAssertEqual(
            Set(pruned),
            Set([
                path(pid: 1, unix: 1_784_000_001),
                path(pid: 1, unix: 1_784_000_002),
                path(pid: 1, unix: 1_784_000_003)
            ]),
            "Should keep the 2 newest by embedded timestamp and prune the rest"
        )
    }

    /// The crux: PIDs are variable-width, so a lexicographic sort of the full
    /// path orders by PID digits before the timestamp. Ranking must parse the
    /// trailing unix field.
    ///
    /// PIDs are chosen so string order and timestamp order actively disagree:
    /// `"9-…"` sorts above `"100-…"` as text, but pid 9 holds the OLDER sample.
    /// A lexicographic implementation therefore keeps the wrong one and this
    /// fails — verified by mutating the sort.
    func testRanksByEmbeddedTimestampNotLexicographically() {
        let newest = path(pid: 100, unix: 1_784_000_900)
        let oldest = path(pid: 9, unix: 1_784_000_100)
        let pruned = MainThreadHangWatchdog.samplesToPrune(
            paths: [newest, oldest],
            keep: 1
        )
        XCTAssertEqual(
            pruned,
            [oldest],
            "Newest sample must survive even though its PID sorts earlier lexicographically"
        )
    }

    func testKeepZeroMeansUnlimitedAndPrunesNothing() {
        let paths = (0..<10).map { path(pid: 1, unix: 1_784_000_000 + $0) }
        XCTAssertEqual(
            MainThreadHangWatchdog.samplesToPrune(paths: paths, keep: 0),
            [],
            "keep=0 is the opt-out for actively debugging a stall; it must prune nothing"
        )
        XCTAssertEqual(
            MainThreadHangWatchdog.samplesToPrune(paths: paths, keep: -1),
            [],
            "Negative keep is also treated as unlimited rather than pruning everything"
        )
    }

    func testFewerSamplesThanKeepPrunesNothing() {
        let paths = [
            path(pid: 1, unix: 1_784_000_001),
            path(pid: 1, unix: 1_784_000_002)
        ]
        XCTAssertEqual(
            MainThreadHangWatchdog.samplesToPrune(paths: paths, keep: 50),
            []
        )
    }

    /// Conservative: anything not matching the exact `-<pid>-<unix>.txt` shape
    /// is not ours to delete.
    func testUnparseablePathsAreNeverPruned() {
        let paths = [
            "/tmp/cmux-hang-sample-notanumber.txt",
            "/tmp/cmux-hang-sample-1-nottime.txt",
            "/tmp/cmux-hang-sample-1.txt",
            "/tmp/unrelated-file.txt",
            path(pid: 1, unix: 1_784_000_001),
            path(pid: 1, unix: 1_784_000_002)
        ]
        let pruned = MainThreadHangWatchdog.samplesToPrune(paths: paths, keep: 1)
        XCTAssertEqual(
            pruned,
            [path(pid: 1, unix: 1_784_000_001)],
            "Only well-formed sample paths are prune candidates"
        )
    }

    func testTiedTimestampsPruneDeterministically() {
        let a = path(pid: 1, unix: 1_784_000_001)
        let b = path(pid: 2, unix: 1_784_000_001)
        let first = MainThreadHangWatchdog.samplesToPrune(paths: [a, b], keep: 1)
        let second = MainThreadHangWatchdog.samplesToPrune(paths: [b, a], keep: 1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(
            first,
            second,
            "Tie-break must not depend on input order, or two launches disagree on the victim"
        )
    }

    /// Lockstep contract: the writer's `samplePath` output must be parseable by
    /// the pruner. If the two ever diverge, `samplesToPrune` would see these as
    /// unrecognised and prune nothing, so a keep=1 result of the older path is
    /// proof the writer format round-trips through the parser.
    func testWriterPathRoundTripsThroughPruner() {
        let older = MainThreadHangWatchdog.samplePath(pid: 4321, unix: 1_784_000_100)
        let newer = MainThreadHangWatchdog.samplePath(pid: 7, unix: 1_784_000_200)
        XCTAssertEqual(
            MainThreadHangWatchdog.samplesToPrune(paths: [older, newer], keep: 1),
            [older],
            "Writer-produced paths must be recognised by the pruner, or retention silently no-ops"
        )
    }

    // MARK: - keep-count resolution

    func testRetentionKeepCountDefaultsWhenEnvAbsent() {
        XCTAssertEqual(
            MainThreadHangWatchdog.retentionKeepCount(env: [:]),
            MainThreadHangWatchdog.defaultRetentionKeepCount
        )
    }

    func testRetentionKeepCountReadsEnvOverride() {
        XCTAssertEqual(
            MainThreadHangWatchdog.retentionKeepCount(env: ["CMUX_HANG_SAMPLE_KEEP": "7"]),
            7
        )
        XCTAssertEqual(
            MainThreadHangWatchdog.retentionKeepCount(env: ["CMUX_HANG_SAMPLE_KEEP": "0"]),
            0,
            "0 must survive as the explicit unlimited opt-out, not fall back to the default"
        )
    }

    func testRetentionKeepCountFallsBackOnGarbageEnv() {
        XCTAssertEqual(
            MainThreadHangWatchdog.retentionKeepCount(env: ["CMUX_HANG_SAMPLE_KEEP": "lots"]),
            MainThreadHangWatchdog.defaultRetentionKeepCount
        )
        XCTAssertEqual(
            MainThreadHangWatchdog.retentionKeepCount(env: ["CMUX_HANG_SAMPLE_KEEP": ""]),
            MainThreadHangWatchdog.defaultRetentionKeepCount
        )
    }
}
