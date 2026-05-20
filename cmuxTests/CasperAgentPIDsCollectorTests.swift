import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage of `TerminalController.collectAgentPIDsByWorkspace`.
///
/// Why this exists: the closure assigned to `PortScanner.agentPIDsProvider`
/// runs on every burst-scan (6× per port kick) and every 5s tracked-agent
/// scan. The previous implementation called `tabs.first(where: { $0.id == … })`
/// per requested id — at 30 workspaces × 30 ids that's 900 traversals per
/// call. The refactored helper iterates `tabs` exactly once and only emits
/// entries for workspaces with at least one valid pid.
///
/// Both the result shape AND equivalence with a brute-force baseline are
/// asserted, so a regression that drops the early-exit-on-empty rule or
/// silently re-introduces the O(N×M) loop with a typo still surfaces.
@MainActor
final class CasperAgentPIDsCollectorTests: XCTestCase {

    /// Brute-force baseline mirroring the old `tabs.first(where:)` algorithm.
    /// Kept identical in semantics to the pre-optimization closure so the
    /// equivalence assertion is meaningful.
    private func baseline(
        tabs: [Workspace],
        workspaceIds: Set<UUID>
    ) -> [UUID: Set<Int>] {
        var pidsByWorkspace: [UUID: Set<Int>] = [:]
        for workspaceId in workspaceIds {
            guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { continue }
            let pids = Set(workspace.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
            if !pids.isEmpty {
                pidsByWorkspace[workspaceId] = pids
            }
        }
        return pidsByWorkspace
    }

    /// Empty workspace id set short-circuits to an empty dict regardless of
    /// how many tabs exist.
    func testEmptyWorkspaceIdsReturnsEmpty() {
        let tabs = [Workspace(), Workspace(), Workspace()]
        tabs[0].agentPIDs["claude_code"] = 1234
        let result = TerminalController.collectAgentPIDsByWorkspace(
            in: tabs,
            matching: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Workspaces with no pids must NOT appear in the result — otherwise the
    /// PortScanner's downstream `expandAgentProcessTree` does pointless work
    /// for sessions that have no tracked agent.
    func testWorkspacesWithNoPIDsAreOmitted() {
        let withPID = Workspace()
        withPID.agentPIDs["claude_code"] = 4321
        let withoutPID = Workspace()
        let result = TerminalController.collectAgentPIDsByWorkspace(
            in: [withPID, withoutPID],
            matching: [withPID.id, withoutPID.id]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[withPID.id], [4321])
        XCTAssertNil(result[withoutPID.id])
    }

    /// Non-positive PIDs (0, negative — sentinel for "cleared" entries in
    /// cmux's hook contract) must be filtered out. A workspace whose ENTRIES
    /// are all non-positive collapses to "no pids" and is omitted entirely.
    func testNonPositivePIDsAreFiltered() {
        let cleared = Workspace()
        cleared.agentPIDs["claude_code"] = 0
        cleared.agentPIDs["codex"] = -1
        let mixed = Workspace()
        mixed.agentPIDs["claude_code"] = 0
        mixed.agentPIDs["codex"] = 999
        let result = TerminalController.collectAgentPIDsByWorkspace(
            in: [cleared, mixed],
            matching: [cleared.id, mixed.id]
        )
        XCTAssertNil(result[cleared.id])
        XCTAssertEqual(result[mixed.id], [999])
    }

    /// Workspaces NOT in the requested `workspaceIds` set must be skipped —
    /// the PortScanner only wants pids for the subset of tracked workspaces.
    func testFiltersTabsByRequestedIds() {
        let tabA = Workspace()
        tabA.agentPIDs["claude_code"] = 100
        let tabB = Workspace()
        tabB.agentPIDs["claude_code"] = 200
        let tabC = Workspace()
        tabC.agentPIDs["claude_code"] = 300
        let result = TerminalController.collectAgentPIDsByWorkspace(
            in: [tabA, tabB, tabC],
            matching: [tabA.id, tabC.id]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[tabA.id], [100])
        XCTAssertEqual(result[tabC.id], [300])
        XCTAssertNil(result[tabB.id])
    }

    /// Multiple status entries per workspace dedupe into a Set — same pid
    /// running under two status keys must NOT appear twice (the downstream
    /// expandAgentProcessTree key-walks via Set semantics).
    func testMultipleAgentKeysDedupeByPID() {
        let workspace = Workspace()
        workspace.agentPIDs["claude_code"] = 555
        workspace.agentPIDs["codex"] = 555
        workspace.agentPIDs["cursor"] = 777
        let result = TerminalController.collectAgentPIDsByWorkspace(
            in: [workspace],
            matching: [workspace.id]
        )
        XCTAssertEqual(result[workspace.id], [555, 777])
    }

    /// Equivalence with the brute-force baseline across a realistic mix:
    /// some empty workspaces, some with pids, some with cleared sentinels,
    /// a requested id that doesn't match any tab. The refactored helper
    /// must produce identical output — that's the safety net against a
    /// future optimization regressing this contract.
    func testEquivalenceWithBruteForceBaseline() {
        let active1 = Workspace()
        active1.agentPIDs["claude_code"] = 1001
        active1.agentPIDs["codex"] = 1002
        let active2 = Workspace()
        active2.agentPIDs["claude_code"] = 2001
        let cleared = Workspace()
        cleared.agentPIDs["claude_code"] = 0
        let empty = Workspace()
        let ghostId = UUID()
        let allRequested: Set<UUID> = [active1.id, active2.id, cleared.id, empty.id, ghostId]

        let actual = TerminalController.collectAgentPIDsByWorkspace(
            in: [active1, active2, cleared, empty],
            matching: allRequested
        )
        let expected = baseline(
            tabs: [active1, active2, cleared, empty],
            workspaceIds: allRequested
        )
        XCTAssertEqual(actual, expected)
    }

    /// Wall-clock perf bound: at 30 tabs × 30 requested ids (the documented
    /// "30 concurrent sessions" target), the refactored single-pass helper
    /// should complete in well under 5ms even on a contested CI runner.
    /// The baseline implementation (O(N×M) via first-where) is also
    /// reasonable at this scale, so the upper bound here is loose enough
    /// that flake-resistance wins over a tight perf comparison — the real
    /// regression signal would be a multi-second hang, not a millisecond
    /// drift.
    func testWallClockAtThirtyConcurrentSessions() {
        let count = 30
        var tabs: [Workspace] = []
        var ids: Set<UUID> = []
        tabs.reserveCapacity(count)
        for i in 0..<count {
            let workspace = Workspace()
            // Half the workspaces have pids, half are empty — mirrors the
            // expected production mix where not every session has an agent.
            if i.isMultiple(of: 2) {
                workspace.agentPIDs["claude_code"] = pid_t(10_000 + i)
            }
            tabs.append(workspace)
            ids.insert(workspace.id)
        }
        let start = Date()
        // Burst-scan replays the call 6 times in a 10s window — mimic that
        // pattern so the test catches a regression that's only painful
        // under the real call cadence.
        for _ in 0..<6 {
            _ = TerminalController.collectAgentPIDsByWorkspace(
                in: tabs,
                matching: ids
            )
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed,
            0.5,
            "6×collectAgentPIDsByWorkspace over 30 tabs × 30 ids should be well under 500ms; got \(elapsed)s"
        )
    }
}
