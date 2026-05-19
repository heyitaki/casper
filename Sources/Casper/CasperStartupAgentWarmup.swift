// CASPER: On session restore, eagerly background-prime agent workspaces so
// their claude/codex/etc. sessions resume on app open instead of waiting for a
// manual click. Reuses the upstream BackgroundWorkspacePrime pipeline
// (`requestBackgroundWorkspaceLoad` → `pendingBackgroundWorkspaceLoadIds` →
// coordinator hidden-mount → surface start → `initialInput` flush) so the only
// Casper-specific bit is the selection policy below.
//
// Selection: any workspace whose snapshot still carries a
// `panels[].terminal.agent` qualifies — that snapshot field is only written
// while the agent is attached, so its mere presence is proof the agent was
// alive at the last save. We do NOT filter on `statusEntries` timestamps
// because those entries are runtime socket reports (`report_status`) that
// aren't reliably persisted/repopulated across restarts. We cap at
// `maxWorkspacesToWarm` and rank by any available recency signal in the
// snapshot, falling back to tab order (sidebar order roughly tracks recency).
//
// Delete if upstream adds a restore-time background prime over the existing
// `restoredAgentAutoResumePendingPanelIds` set.

import Foundation

@MainActor
enum CasperStartupAgentWarmup {
    /// Hard ceiling on warmups per restore. Each warm spins a hidden ghostty
    /// surface plus an agent process (`claude --resume`, `codex resume`, etc.),
    /// so the cap is the budget for "useful preload" before paying real memory
    /// + CPU cost.
    static let maxWorkspacesToWarm = 5

    /// Pure selection — pick the workspace IDs to warm. `pairs` carries the
    /// `(id, workspace)` correspondence directly so the alignment invariant is
    /// structural rather than positional-by-convention.
    static func workspaceIdsToWarm(
        pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)],
        selectedWorkspaceId: UUID?
    ) -> [UUID] {
        guard !pairs.isEmpty else { return [] }

        // Composite recency key: explicit timestamp (status or log entry) if
        // available, otherwise tab-order tiebreaker (earlier in tabs ⇒ more
        // recent in the sidebar's view). Sort descending.
        var candidates: [(id: UUID, score: Double)] = []
        candidates.reserveCapacity(pairs.count)

        for (i, pair) in pairs.enumerated() {
            if pair.id == selectedWorkspaceId { continue }
            let ws = pair.workspace
            guard ws.panels.contains(where: { $0.terminal?.agent != nil }) else { continue }

            let statusMax = ws.statusEntries.lazy.map(\.timestamp).max() ?? 0
            let logMax = ws.logEntries.lazy.map(\.timestamp).max() ?? 0
            let explicit = max(statusMax, logMax)
            // Synthetic fallback: tab order. Multiply by a small epsilon so a
            // real timestamp always beats a positional one.
            let synthetic = -Double(i) * 0.001
            let score = explicit > 0 ? explicit : synthetic
            candidates.append((pair.id, score))
        }

        candidates.sort { $0.score > $1.score }
        return candidates.prefix(maxWorkspacesToWarm).map(\.id)
    }

    /// Enqueue warmup for chosen workspaces. The upstream
    /// `BackgroundWorkspacePrimeCoordinator` (`ContentView.swift` `.task(id:)`
    /// keyed on `pendingBackgroundWorkspaceLoadIds`) picks them up on its next
    /// tick, hidden-mounts each, lets the surface spawn, and releases.
    ///
    /// Gated on `AgentSessionAutoResumeSettings.isEnabled()` — if the user
    /// turned auto-resume off, `restoredAgentResumeInput` is nil so warming
    /// would only spawn an empty shell, which isn't worth the boot cost.
    static func applyStartupWarmup(
        tabManager: TabManager,
        snapshot: SessionTabManagerSnapshot
    ) {
        let autoResumeEnabled = AgentSessionAutoResumeSettings.isEnabled()
        let tabIds = tabManager.tabs.map(\.id)
        let selectedId = tabManager.selectedTabId

        guard autoResumeEnabled else {
#if DEBUG
            cmuxDebugLog("casper.startupWarmup.skip autoResume=false")
#endif
            return
        }

        let pairs = zip(tabIds, snapshot.workspaces).map { (id: $0, workspace: $1) }
        let ids = workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: selectedId
        )
        for id in ids {
            tabManager.requestBackgroundWorkspaceLoad(for: id)
        }
#if DEBUG
        let agentPanelCount = snapshot.workspaces.reduce(0) { acc, ws in
            acc + (ws.panels.contains(where: { $0.terminal?.agent != nil }) ? 1 : 0)
        }
        let preview = ids.map { $0.uuidString.prefix(5) }.joined(separator: ",")
        cmuxDebugLog(
            "casper.startupWarmup.enqueue count=\(ids.count) " +
                "of agentPanelWorkspaces=\(agentPanelCount) " +
                "tabs=\(tabIds.count) selected=\(selectedId?.uuidString.prefix(5) ?? "nil") " +
                "ids=\(preview)"
        )
#endif
    }
}
