// CASPER: per-workspace agent activity state derived from cmux's existing
// hook-driven `Workspace.statusEntries` (set by `cmux hooks <agent> *` from
// Resources/bin/{claude,codex}). Maps the cmux status entries to a 4-state
// model (working / needsInput / done / none) that the compact sidebar row
// renders. Delete if upstream adds a first-class agent-state surface on
// Workspace.

import Foundation
import SQLite3
import SwiftUI

/// 4-state activity classification for a single workspace.
///
/// Mapping from cmux's `set_status <agentKey> <value>` calls
/// (see CLI/cmux.swift `setClaudeStatus` and `runGenericAgentHook`):
/// - working    : entry value is anything other than "Idle" / "Needs input" / failure
///                — Claude Code "Running" (or verbose-status tool description),
///                  Codex/Gemini/etc. "Running"
/// - needsInput : entry value matches "Needs input" / "Waiting" / failure (red),
///                or unread cmux notifications exist while an agent entry is present
/// - done       : entry value matches "Idle"
/// - none       : no agent status entries at all
///                — i.e. SessionEnd hook (Ctrl+C path) ran `clear_agent_pid …
///                  --clear-status`, or no agent has run in this workspace
enum CasperWorkspaceActivityState: Int, Comparable, Equatable, Sendable {
    case none = 0
    case done = 1
    case needsInput = 2
    case working = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct CasperWorkspaceActivity: Equatable, Sendable {
    let state: CasperWorkspaceActivityState
    let lastActivityAt: Date?
}

@MainActor
enum CasperAgentActivity {
    /// Status keys that cmux's hook system uses for agent entries
    /// (CLI/CMUXCLI+AgentHookDefinitions.swift `agentDefs[*].statusKey`,
    /// plus claude's hardcoded "claude_code" key from `setClaudeStatus`).
    /// Stored lowercased to match `Workspace.statusEntries` keys
    /// case-insensitively.
    static let agentStatusKeys: Set<String> = [
        "claude_code",
        "codex",
        "cursor",
        "gemini",
        "opencode",
        "pi",
        "rovodev",
        "hermes-agent",
        "copilot",
        "codebuddy",
        "factory",
        "qoder",
    ]

    static func activity(
        for workspace: Workspace,
        notificationStore: TerminalNotificationStore
    ) -> CasperWorkspaceActivity {
        return classifyWorkspaceScoped(
            agentEntries: allAgentEntries(in: workspace),
            workspace: workspace,
            notificationStore: notificationStore
        )
    }

    /// Workspace-scoped candidate bundle, shared by `activity(for:)` and the
    /// single-terminal `panelActivity` branch (panel == workspace there) so
    /// the two call sites can't drift on what "workspace scope" includes.
    private static func classifyWorkspaceScoped(
        agentEntries: [SidebarStatusEntry],
        workspace: Workspace,
        notificationStore: TerminalNotificationStore
    ) -> CasperWorkspaceActivity {
        classifyActivity(
            agentEntries: agentEntries,
            unreadCount: notificationStore.unreadCount(forTabId: workspace.id),
            notificationDate: notificationStore.latestNotification(forTabId: workspace.id)?.createdAt,
            claudeHistoryDate: claudeActivityDate(for: workspace),
            codexHistoryDate: codexActivityDate(for: workspace)
        )
    }

    /// Per-panel activity. Only considers status entries whose agent PID key
    /// maps to `panelId` via `workspace.agentPIDKeysByPanelId`. Panels with
    /// no attributed agent entries fall through to `.done` / `.none` via the
    /// JSONL and notification paths (same as workspace-level).
    ///
    /// `terminalPanelCount` must be the TERMINAL-only panel count the caller
    /// derived for its multi-panel decision (browser/markdown panels are not
    /// sidebar rows) — using `workspace.panels.count` here silently disagreed
    /// with the sidebar's filtered count for 1-terminal + N-browser
    /// workspaces, which would misroute to the multi-panel branch and drop
    /// the workspace-level fallback.
    static func panelActivity(
        for workspace: Workspace,
        panelId: UUID,
        notificationStore: TerminalNotificationStore,
        terminalPanelCount: Int
    ) -> CasperWorkspaceActivity {
        let panelStatusKeys = workspace.agentPIDKeysByPanelId[panelId] ?? []
        if panelStatusKeys.isEmpty {
            if terminalPanelCount <= 1 {
                return activity(for: workspace, notificationStore: notificationStore)
            }
            // Multi-panel, no live PID attribution — check per-panel JSONL
            // dates so panels retain their "done" timestamp after session-end
            // clears the PID + status atomically. Most-recent agent wins.
            let panelDates = [
                claudeActivityDate(forPanelId: panelId, in: workspace),
                codexActivityDate(forPanelId: panelId),
            ]
            if let panelDate = panelDates.compactMap({ $0 }).max() {
                return CasperWorkspaceActivity(state: .done, lastActivityAt: panelDate)
            }
            return CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
        }
        let agentEntries = panelStatusKeys.compactMap { pidKey -> SidebarStatusEntry? in
            let statusKey = statusKeyForPIDKey(pidKey, in: workspace)
            guard agentStatusKeys.contains(statusKey.lowercased()) else { return nil }
            return workspace.statusEntries[statusKey]
        }
        if terminalPanelCount <= 1 {
            // Single terminal: panel == workspace, and the panel-keyed
            // activity stores aren't populated for single-panel workspaces —
            // workspace-scoped candidates ARE this panel's candidates.
            return classifyWorkspaceScoped(
                agentEntries: agentEntries,
                workspace: workspace,
                notificationStore: notificationStore
            )
        }
        // Multi-panel: every candidate must be scoped to THIS panel. Passing
        // workspace-level JSONL/notification dates here made all sibling rows
        // report the most-recently-active sibling's time (the aggregation this
        // file's attribution machinery exists to avoid).
        let latestNotification = notificationStore.latestNotification(forTabId: workspace.id)
        return classifyActivity(
            agentEntries: agentEntries,
            unreadCount: notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId) ? 1 : 0,
            notificationDate: latestNotification?.surfaceId == panelId ? latestNotification?.createdAt : nil,
            claudeHistoryDate: claudeActivityDate(forPanelId: panelId, in: workspace),
            codexHistoryDate: codexActivityDate(forPanelId: panelId)
        )
    }

    private static func allAgentEntries(in workspace: Workspace) -> [SidebarStatusEntry] {
        workspace.statusEntries.compactMap { key, entry in
            agentStatusKeys.contains(key.lowercased()) ? entry : nil
        }
    }

    /// Mirror of `Workspace.agentStatusKey(forAgentPIDKey:)` — strips the
    /// `.pid` suffix from a PID key to recover the status-entry key.
    /// Canonical implementation: `Workspace+PanelLifecycle.swift`.
    private static func statusKeyForPIDKey(_ pidKey: String, in workspace: Workspace) -> String {
        if workspace.statusEntries[pidKey] != nil { return pidKey }
        guard let dotIndex = pidKey.firstIndex(of: ".") else { return pidKey }
        return String(pidKey[..<dotIndex])
    }

    /// Pure classification over caller-scoped candidates. Callers decide the
    /// attribution scope: `activity(for:)` passes workspace-level candidates,
    /// `panelActivity` passes panel-level ones — classification itself never
    /// reaches back into workspace-wide state, so a panel row can't inherit a
    /// sibling's timestamp.
    ///
    /// `lastActivityAt` is the max across every scoped candidate for all
    /// states (a working session keeps sorting by its live JSONL stream, not
    /// the status-change instant).
    ///
    /// History candidates are "real user-visible activity" only. We
    /// deliberately exclude `workspace.logEntries.last?.timestamp` even
    /// though it has a timestamp — `appendSidebarLog` fires `Date()` for
    /// system events like port-conflict warnings during terminal reconnect,
    /// which pegs every restored workspace to "<1m" the moment they come
    /// back. Same category as `/resume` / `/compact`: not real user activity.
    ///
    /// Claude JSONL is the history fallback (parsed off-main into
    /// `CasperClaudeActivityStore`) — the latest real user/assistant message
    /// timestamp in `~/.claude/projects/<dashed-cwd>/*.jsonl`, skipping
    /// metadata-only resume records and compact-summary turns.
    static func classifyActivity(
        agentEntries: [SidebarStatusEntry],
        unreadCount: Int,
        notificationDate: Date?,
        claudeHistoryDate: Date?,
        codexHistoryDate: Date?
    ) -> CasperWorkspaceActivity {
        let agentMax = agentEntries.map(\.timestamp).max()
        let lastActivityAt = [agentMax, notificationDate, claudeHistoryDate, codexHistoryDate]
            .compactMap { $0 }
            .max()
        // WORKING / NEEDS_INPUT only fire when cmux's hook system has live
        // agent state. Working wins over everything; needs-input includes
        // unread notifications even if the agent entry says Idle.
        if agentEntries.contains(where: isWorkingValue) {
            return CasperWorkspaceActivity(state: .working, lastActivityAt: lastActivityAt)
        }
        if agentEntries.contains(where: isNeedsInputValue) || (unreadCount > 0 && !agentEntries.isEmpty) {
            return CasperWorkspaceActivity(state: .needsInput, lastActivityAt: lastActivityAt)
        }
        if let lastActivityAt {
            return CasperWorkspaceActivity(state: .done, lastActivityAt: lastActivityAt)
        }
        return CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
    }

    /// Snapshot read against `CasperClaudeActivityStore` — dict lookups only,
    /// no file I/O (the path fallback may TTL-kick the hook map's off-main
    /// refresh, same as the sidebar's own `claudeJSONLPaths` body reads). The
    /// store is refreshed off-main by the sidebar whenever the visible
    /// workspaces' JSONL path set changes. When the UUID-keyed runtime map has
    /// no entry yet (cold start: workspace/panel UUIDs are minted fresh on
    /// every session restore, so no UUID survives a relaunch), falls back to
    /// the path-keyed disk cache via this workspace's memoized JSONL paths.
    private static func claudeActivityDate(for workspace: Workspace) -> Date? {
        if let live = CasperClaudeActivityStore.shared.latestActivity(forWorkspaceID: workspace.id) {
            return live
        }
        return CasperClaudeActivityStore.shared.latestActivity(
            forJSONLPaths: claudeJSONLPaths(for: workspace)
        )
    }

    private static func claudeActivityDate(forPanelId panelId: UUID, in workspace: Workspace) -> Date? {
        if let live = CasperClaudeActivityStore.shared.latestActivity(forPanelID: panelId) {
            return live
        }
        return CasperClaudeActivityStore.shared.latestActivity(
            forJSONLPaths: claudeJSONLPaths(forPanel: panelId, in: workspace)
        )
    }

    private static func codexActivityDate(for workspace: Workspace) -> Date? {
        CasperCodexActivityStore.shared.latestActivity(forWorkspaceID: workspace.id)
    }

    private static func codexActivityDate(forPanelId panelId: UUID) -> Date? {
        CasperCodexActivityStore.shared.latestActivity(forPanelID: panelId)
    }

    /// JSONL paths to scan for this workspace's last activity. Always tied
    /// to a specific session — never aggregates across siblings:
    /// 1. Hook records (`~/.cmuxterm/claude-hook-sessions.json`) — the
    ///    SessionStart hook records `(workspaceId, sessionId, cwd)` per
    ///    Claude launch.
    /// 2. Restored agent snapshots — session persistence stores each panel's
    ///    `(sessionId, workingDirectory)` under `terminal.agent`, so workspaces
    ///    that came back from disk (no live hook record) still attribute to
    ///    their own JSONL.
    /// 3. Neither → []. We deliberately do NOT fall back to "every JSONL in
    ///    `~/.claude/projects/<encoded-cwd>/`": that aggregated max(time)
    ///    across every sibling session in the project dir, pegging every
    ///    workspace sharing a cwd (e.g. all `~/code/pixie` tabs) to the
    ///    most-recently-active sibling's time. Better to show no time than
    ///    a wildly misleading one.
    /// Paths are sorted so equal sets compare equal wherever they're used as
    /// grouping/refresh keys, independent of dict iteration order.
    static func claudeJSONLPaths(
        for workspace: Workspace,
        now: Date = Date()
    ) -> [String] {
        // Memoize per-workspace because this is called from SwiftUI body
        // (VerticalTabsSidebar.workspaceRows) on every re-eval. Key contains
        // every input the computation reads.
        let key = CasperClaudeJSONLPathsCache.Key(
            hookVersion: CasperClaudeSessionMap.shared.mapVersion,
            snapshotsHash: claudeSnapshotSignature(for: workspace)
        )
        if let cached = CasperClaudeJSONLPathsCache.lookup(workspaceId: workspace.id, key: key, now: now) {
            return cached
        }
        let result = computeClaudeJSONLPaths(for: workspace)
        CasperClaudeJSONLPathsCache.store(workspaceId: workspace.id, key: key, value: result, now: now)
        return result
    }

    private static func computeClaudeJSONLPaths(for workspace: Workspace) -> [String] {
        let hookPaths = CasperClaudeSessionMap.shared.jsonlPaths(forWorkspaceID: workspace.id)
        if !hookPaths.isEmpty { return hookPaths.sorted() }
        return claudeSnapshotJSONLPaths(for: workspace).sorted()
    }

    static func claudeJSONLPaths(
        forPanel panelId: UUID,
        in workspace: Workspace,
        now: Date = Date()
    ) -> [String] {
        // Memoized like the workspace variant above — this runs from
        // SwiftUI body for every panel of every multi-panel workspace on
        // each sidebar re-eval, and the uncached path paid a hook-map
        // kickRefresh plus a fresh sorted() allocation per call.
        let key = CasperClaudeJSONLPathsCache.Key(
            hookVersion: CasperClaudeSessionMap.shared.mapVersion,
            snapshotsHash: claudePanelSnapshotSignature(forPanel: panelId, in: workspace)
        )
        if let cached = CasperClaudeJSONLPathsCache.lookupPanel(panelId: panelId, key: key, now: now) {
            return cached
        }
        let hookPaths = CasperClaudeSessionMap.shared.jsonlPaths(forPanelID: panelId)
        let result = hookPaths.isEmpty
            ? claudeSnapshotJSONLPaths(forPanel: panelId, in: workspace).sorted()
            : hookPaths.sorted()
        CasperClaudeJSONLPathsCache.storePanel(panelId: panelId, key: key, value: result, now: now)
        return result
    }

    /// Panel analogue of `claudeSnapshotSignature` — content hash of the one
    /// snapshot this panel can attribute to, for cache keying.
    private static func claudePanelSnapshotSignature(forPanel panelId: UUID, in workspace: Workspace) -> Int {
        var hasher = Hasher()
        if let snapshot = workspace.restoredAgentSnapshotsByPanelId[panelId], snapshot.kind == .claude {
            hasher.combine(snapshot.sessionId)
            hasher.combine(snapshot.workingDirectory ?? "")
        }
        return hasher.finalize()
    }

    private static func claudeSnapshotJSONLPaths(forPanel panelId: UUID, in workspace: Workspace) -> [String] {
        guard let snapshot = workspace.restoredAgentSnapshotsByPanelId[panelId],
              snapshot.kind == .claude else { return [] }
        let sid = snapshot.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else { return [] }
        let cwd = (snapshot.workingDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return [] }
        return [CasperClaudeSessionPath.jsonlPath(sessionId: sid, cwd: cwd)]
    }

    /// Session-attributed fallback paths used when the live hook map has no
    /// record for this workspace — typically because the workspace was
    /// restored from session persistence and Claude hasn't relaunched yet.
    /// Returns `[]` when there are no claude snapshots: the caller treats
    /// that as "no attribution available" and surfaces no trailing time
    /// rather than risk a misleading aggregate across siblings.
    private static func claudeSnapshotJSONLPaths(for workspace: Workspace) -> [String] {
        // Dedup so two panels sharing the same `(sessionId, cwd)` produce one
        // path — keeps the activity store's per-path-set grouping aligned with
        // single-panel workspaces pointing at the same JSONL.
        var paths: Set<String> = []
        for (sid, cwd) in validClaudeSnapshots(for: workspace) {
            paths.insert(CasperClaudeSessionPath.jsonlPath(sessionId: sid, cwd: cwd))
        }
        return Array(paths)
    }

    /// Stable hash of the workspace's claude snapshot identity for cache
    /// keying. Pairs are sorted so the value doesn't depend on dict
    /// iteration order.
    private static func claudeSnapshotSignature(for workspace: Workspace) -> Int {
        let pairs = validClaudeSnapshots(for: workspace)
            .sorted { lhs, rhs in
                lhs.sid == rhs.sid ? lhs.cwd < rhs.cwd : lhs.sid < rhs.sid
            }
        var hasher = Hasher()
        for pair in pairs {
            hasher.combine(pair.sid)
            hasher.combine(pair.cwd)
        }
        return hasher.finalize()
    }

    /// `(sessionId, workingDirectory)` pairs from this workspace's restored
    /// claude snapshots, with empty/whitespace entries dropped. Shared by
    /// `claudeSnapshotJSONLPaths` (path builder) and `claudeSnapshotSignature`
    /// (cache key) so the validation rules can't drift between them.
    private static func validClaudeSnapshots(
        for workspace: Workspace
    ) -> [(sid: String, cwd: String)] {
        workspace.restoredAgentSnapshotsByPanelId.values.compactMap { snapshot in
            guard snapshot.kind == .claude else { return nil }
            let sid = snapshot.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sid.isEmpty else { return nil }
            let cwd = (snapshot.workingDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { return nil }
            return (sid, cwd)
        }
    }

    static func codexSessionIDs(
        for workspace: Workspace
    ) -> [String] {
        let hookIDs = CasperCodexSessionMap.shared.sessionIDs(forWorkspaceID: workspace.id)
        return hookIDs.isEmpty ? codexSnapshotSessionIDs(for: workspace) : hookIDs.sorted()
    }

    static func codexSessionIDs(
        forPanel panelId: UUID,
        in workspace: Workspace
    ) -> [String] {
        let hookIDs = CasperCodexSessionMap.shared.sessionIDs(forPanelID: panelId)
        return hookIDs.isEmpty ? codexSnapshotSessionIDs(forPanel: panelId, in: workspace) : hookIDs.sorted()
    }

    private static func codexSnapshotSessionIDs(forPanel panelId: UUID, in workspace: Workspace) -> [String] {
        guard let snapshot = workspace.restoredAgentSnapshotsByPanelId[panelId],
              snapshot.kind == .codex else { return [] }
        let sid = snapshot.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return sid.isEmpty ? [] : [sid]
    }

    private static func codexSnapshotSessionIDs(for workspace: Workspace) -> [String] {
        var ids: Set<String> = []
        for snapshot in workspace.restoredAgentSnapshotsByPanelId.values where snapshot.kind == .codex {
            let sid = snapshot.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sid.isEmpty { ids.insert(sid) }
        }
        return ids.sorted()
    }

    /// Sort comparator: pinned-first, then activity-desc with `.none` last.
    /// Reads precomputed activity from `activityByID` so the comparator is a
    /// pure dict lookup — never re-derives activity inside the sort, which
    /// otherwise multiplies cost by `O(N log N)` per render.
    static func compareActivityDesc(
        lhs: Workspace,
        rhs: Workspace,
        activityByID: [Workspace.ID: CasperWorkspaceActivity]
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        let lhsActivity = activityByID[lhs.id] ?? CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
        let rhsActivity = activityByID[rhs.id] ?? CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
        if (lhsActivity.state == .none) != (rhsActivity.state == .none) {
            return rhsActivity.state == .none
        }
        let lhsTime = lhsActivity.lastActivityAt ?? .distantPast
        let rhsTime = rhsActivity.lastActivityAt ?? .distantPast
        return lhsTime > rhsTime
    }

    /// Entry-level analogue of `compareActivityDesc` used to order individual
    /// session rows *within* a folder group, so a workspace's split-panels are
    /// no longer forced adjacent — every row sits at its own recency. Returns
    /// true when `lhs` should sort before `rhs`. `false` for ties (the caller
    /// applies a stable index tiebreak). Mirrors the workspace comparator:
    /// pinned-first, then `.none` activity sinks to the bottom, then most
    /// recent `lastActivityAt` wins.
    static func compareEntryActivityDesc(
        lhs: CasperSidebarPanelEntry,
        rhs: CasperSidebarPanelEntry
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        if (lhs.activity.state == .none) != (rhs.activity.state == .none) {
            return rhs.activity.state == .none
        }
        let lhsTime = lhs.activity.lastActivityAt ?? .distantPast
        let rhsTime = rhs.activity.lastActivityAt ?? .distantPast
        return lhsTime > rhsTime
    }

    private static func isWorkingValue(_ entry: SidebarStatusEntry) -> Bool {
        let normalized = entry.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if normalized == "idle" { return false }
        if normalized.contains("needs input") || normalized.contains("waiting") { return false }
        if isFailureEntry(entry) { return false }
        return true
    }

    private static func isNeedsInputValue(_ entry: SidebarStatusEntry) -> Bool {
        let normalized = entry.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("needs input") || normalized.contains("waiting") {
            return true
        }
        return isFailureEntry(entry)
    }

    /// Codex `summarizeCodexHookFailure` sets the entry icon/color to the
    /// red exclamation glyph; treat as needs-input so the workspace stays
    /// surfaced until the user acks it.
    private static func isFailureEntry(_ entry: SidebarStatusEntry) -> Bool {
        if entry.icon == "exclamationmark.triangle.fill" { return true }
        if let color = entry.color?.lowercased(), color == "#ff453a" { return true }
        return false
    }
}

// MARK: - Off-main Claude JSONL activity cache

/// Shared formatter for Claude JSONL `timestamp` fields and the disk
/// activity cache — same options across all callsites.
/// `ISO8601DateFormatter` is thread-safe (macOS 10.13+), so a single
/// instance is reused across the off-main scan and the on-main disk
/// load/save paths.
private let casperISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Encodes `(sessionId, cwd)` into Claude Code's on-disk JSONL path:
/// `~/.claude/projects/<dashed-cwd>/<sessionId>.jsonl`. Single source of
/// truth for the encoding rule — used by the hook session map parser, the
/// workspace-level snapshot fallback, and the per-panel snapshot fallback.
enum CasperClaudeSessionPath {
    /// Claude Code encodes the project dir by replacing every non-alphanumeric
    /// UTF-16 code unit of the cwd with "-" (cli.js `replace(/[^a-zA-Z0-9]/g,
    /// "-")`), NOT just "/": `/Users/x/code/foo.bar` → `-Users-x-code-foo-bar`,
    /// `/Users/x/.worktrees/y` → `-Users-x--worktrees-y`. Replacing only "/"
    /// pointed dotted/underscored cwds at nonexistent project dirs, so those
    /// sessions never surfaced a sidebar timestamp.
    static func jsonlPath(sessionId: String, cwd: String) -> String {
        let units = cwd.utf16.map { unit -> UInt16 in
            let isAlphanumeric = (unit >= 0x30 && unit <= 0x39)
                || (unit >= 0x41 && unit <= 0x5A)
                || (unit >= 0x61 && unit <= 0x7A)
            return isAlphanumeric ? unit : 0x2D // "-"
        }
        let encoded = String(utf16CodeUnits: units, count: units.count)
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl")
    }
}

/// Maps cmux workspace UUIDs to the Claude Code session JSONL paths cmux's
/// hook system has recorded for that workspace, by reading
/// `~/.cmuxterm/claude-hook-sessions.json` (written by
/// `RestorableAgentHookSessionStoreFile` via the SessionStart hook in
/// `Resources/bin/claude`).
///
/// Cached on the hook file's mtime — the hook file is rewritten whenever a
/// session is registered or cleared, so mtime is a tight invalidation key
/// and lookups are pure dict reads on the hot path. Workspace-keying is
/// required because a single cwd (e.g. `/Users/aki/code/cmux`) may host many
/// workspaces, and per-cwd attribution pegs every sibling workspace to the
/// most-recently-active session's timestamp.
@MainActor
final class CasperClaudeSessionMap: ObservableObject {
    static let shared = CasperClaudeSessionMap()

    private struct CachedState {
        let mtime: Date
        let map: [UUID: [String]]
        let panelMap: [UUID: [String]]
    }

    private var cached: CachedState?

    /// Version stamp for the cached hook map. Bumps only when the hook store
    /// file's mtime changes (a session was registered/cleared). View body
    /// callers use this as part of memoization keys; SwiftUI subscribes via
    /// `@ObservedObject` on the sidebar so a new session triggers a re-eval
    /// + `.task(id:)` restart.
    @Published private(set) var mapVersion: TimeInterval = 0

    private let refreshQueue = DispatchQueue(
        label: "casper.claude-session-map.refresh",
        qos: .userInitiated
    )
    private var refreshInFlight = false
    private var lastRefreshKickAt: Date = .distantPast
    /// Skip kicking another off-main refresh within this window. At N=50
    /// workspaces, body-driven `jsonlPaths(forWorkspaceID:)` reads would
    /// otherwise kick 50× per re-eval. 2s is short enough that a freshly
    /// registered session shows up almost immediately.
    private let refreshKickTTL: TimeInterval = 2.0

    init() {
        // `lastRefreshKickAt` defaults to `.distantPast`, so the TTL gate
        // passes naturally on this first call — cold-start primes the cache
        // without needing a separate force path.
        kickRefresh()
    }

    /// Pure dict read. Schedules a best-effort off-main refresh if the cache
    /// is stale (gated by `refreshKickTTL`). NEVER blocks the caller — view
    /// body sees the current snapshot, and the next body re-eval after the
    /// refresh completes picks up updates via `@Published mapVersion`.
    func jsonlPaths(forWorkspaceID id: UUID) -> [String] {
        kickRefresh()
        return cached?.map[id] ?? []
    }

    func jsonlPaths(forPanelID id: UUID) -> [String] {
        kickRefresh()
        return cached?.panelMap[id] ?? []
    }

    /// Best-effort off-main refresh, TTL-gated and in-flight-coalesced.
    /// Safe to call from view body — schedules work on a background queue
    /// and posts back via `@Published mapVersion`.
    func kickRefresh() {
        if refreshInFlight { return }
        let now = Date()
        if now.timeIntervalSince(lastRefreshKickAt) < refreshKickTTL { return }
        refreshInFlight = true
        lastRefreshKickAt = now
        let priorMtime = cached?.mtime
        refreshQueue.async { [weak self] in
            let next = Self.computeRefresh(priorMtime: priorMtime)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard let next else { return }
                self.cached = next
                self.mapVersion = next.mtime.timeIntervalSinceReferenceDate
            }
        }
    }

    private static func computeRefresh(priorMtime: Date?) -> CachedState? {
        // Route through `RestorableAgentKind.claude.hookStoreFileURL()` so
        // the `CMUX_AGENT_HOOK_STATE_DIR` override is honored — otherwise
        // Casper reads `~/.cmuxterm/...` while the hook writer
        // (Resources/bin/claude) writes to the override dir, and
        // per-workspace attribution silently falls through to the cwd
        // fallback. The function is non-isolated, safe to call from this
        // background queue.
        let path = RestorableAgentKind.claude.hookStoreFileURL().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        if priorMtime == mtime { return nil }
        let (workspaceMap, panelMap) = parse(path: path)
        return CachedState(mtime: mtime, map: workspaceMap, panelMap: panelMap)
    }

    private static func parse(path: String) -> (workspace: [UUID: [String]], panel: [UUID: [String]]) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: [String: Any]]
        else { return ([:], [:]) }
        var workspaceOut: [UUID: [String]] = [:]
        var panelOut: [UUID: [String]] = [:]
        for (sessionId, record) in sessions {
            guard let workspaceIdString = record["workspaceId"] as? String,
                  let workspaceId = UUID(uuidString: workspaceIdString),
                  let cwd = record["cwd"] as? String
            else { continue }
            let jsonlPath = CasperClaudeSessionPath.jsonlPath(sessionId: sessionId, cwd: cwd)
            workspaceOut[workspaceId, default: []].append(jsonlPath)
            if let surfaceIdString = record["surfaceId"] as? String,
               let surfaceId = UUID(uuidString: surfaceIdString) {
                panelOut[surfaceId, default: []].append(jsonlPath)
            }
        }
        return (workspaceOut, panelOut)
    }
}

/// Maps cmux workspace UUIDs to Codex native session IDs by reading the
/// shared hook-session store (`~/.cmuxterm/codex-hook-sessions.json`).
/// Codex activity is then resolved through Codex's own SQLite thread index,
/// not by scanning every rollout file.
@MainActor
final class CasperCodexSessionMap: ObservableObject {
    static let shared = CasperCodexSessionMap()

    private struct CachedState {
        let mtime: Date
        let map: [UUID: [String]]
        let panelMap: [UUID: [String]]
    }

    private var cached: CachedState?

    @Published private(set) var mapVersion: TimeInterval = 0

    private let refreshQueue = DispatchQueue(
        label: "casper.codex-session-map.refresh",
        qos: .userInitiated
    )
    private var refreshInFlight = false
    private var lastRefreshKickAt: Date = .distantPast
    private let refreshKickTTL: TimeInterval = 2.0

    init() {
        kickRefresh()
    }

    func sessionIDs(forWorkspaceID id: UUID) -> [String] {
        kickRefresh()
        return cached?.map[id] ?? []
    }

    func sessionIDs(forPanelID id: UUID) -> [String] {
        kickRefresh()
        return cached?.panelMap[id] ?? []
    }

    func kickRefresh() {
        if refreshInFlight { return }
        let now = Date()
        if now.timeIntervalSince(lastRefreshKickAt) < refreshKickTTL { return }
        refreshInFlight = true
        lastRefreshKickAt = now
        let priorMtime = cached?.mtime
        refreshQueue.async { [weak self] in
            let next = Self.computeRefresh(priorMtime: priorMtime)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard let next else { return }
                self.cached = next
                self.mapVersion = next.mtime.timeIntervalSinceReferenceDate
            }
        }
    }

    private static func computeRefresh(priorMtime: Date?) -> CachedState? {
        let path = RestorableAgentKind.codex.hookStoreFileURL().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        if priorMtime == mtime { return nil }
        let (workspaceMap, panelMap) = parse(path: path)
        return CachedState(mtime: mtime, map: workspaceMap, panelMap: panelMap)
    }

    private static func parse(path: String) -> (workspace: [UUID: [String]], panel: [UUID: [String]]) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: [String: Any]]
        else { return ([:], [:]) }
        var workspaceOut: [UUID: [String]] = [:]
        var panelOut: [UUID: [String]] = [:]
        for (sessionId, record) in sessions {
            let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSessionId.isEmpty,
                  let workspaceIdString = record["workspaceId"] as? String,
                  let workspaceId = UUID(uuidString: workspaceIdString)
            else { continue }
            workspaceOut[workspaceId, default: []].append(trimmedSessionId)
            if let surfaceIdString = record["surfaceId"] as? String,
               let surfaceId = UUID(uuidString: surfaceIdString) {
                panelOut[surfaceId, default: []].append(trimmedSessionId)
            }
        }
        return (workspaceOut, panelOut)
    }
}

/// Cheap, stable id for `VerticalTabsSidebar`' agent-activity poll task.
/// Hashing the full `[UUID: [String]]` maps on every body eval costs hundreds
/// of string hashes; these fields capture the inputs that should restart the
/// poll loop.
struct CasperAgentSessionsTaskID: Hashable {
    let mapVersion: TimeInterval
    let codexMapVersion: TimeInterval
    let workspaceIDs: Set<UUID>
}

/// Per-workspace memoization of `CasperAgentActivity.claudeJSONLPaths`.
/// The function runs inside `VerticalTabsSidebar.workspaceRows`' reduce on
/// every body re-eval (driven by the 20s `latestActivityByWorkspace`
/// publish). Without this cache, each tab's directory iteration + sort
/// added up to ~7s of every 17s body cycle for 48 open workspaces.
@MainActor
enum CasperClaudeJSONLPathsCache {
    struct Key: Hashable {
        /// `CasperClaudeSessionMap.mapVersion` — bumps whenever the hook
        /// store file is reparsed.
        let hookVersion: TimeInterval
        /// Content hash of the workspace's `(sessionId, workingDirectory)`
        /// claude restored-snapshot pairs. `Set.hashValue` uses the
        /// process-randomized hash seed, so this Key is in-process only —
        /// never persist it.
        let snapshotsHash: Int
    }
    private struct Entry {
        let key: Key
        let value: [String]
        let computedAt: Date
    }
    private static var entries: [UUID: Entry] = [:]
    /// Short window so a JSONL crossing the 120s `liveCutoff` boundary
    /// (which isn't part of the key) surfaces within ~3s. The cache exists
    /// to coalesce body re-eval bursts, not to suppress real updates.
    private static let ttl: TimeInterval = 3.0
    /// Cap so closed-workspace orphans don't accumulate indefinitely. When
    /// tripped, drop entries past their TTL; they would re-compute on the
    /// next access anyway.
    private static let maxEntries = 256

    static func lookup(workspaceId: UUID, key: Key, now: Date) -> [String]? {
        lookupEntry(in: entries, id: workspaceId, key: key, now: now)
    }

    static func store(workspaceId: UUID, key: Key, value: [String], now: Date) {
        storeEntry(in: &entries, id: workspaceId, key: key, value: value, now: now)
    }

    // Panel-keyed entries live in their own dict so workspace and panel
    // UUID namespaces can't collide (same discipline as the activity
    // store's split in-flight sets).
    private static var panelEntries: [UUID: Entry] = [:]

    static func lookupPanel(panelId: UUID, key: Key, now: Date) -> [String]? {
        lookupEntry(in: panelEntries, id: panelId, key: key, now: now)
    }

    static func storePanel(panelId: UUID, key: Key, value: [String], now: Date) {
        storeEntry(in: &panelEntries, id: panelId, key: key, value: value, now: now)
    }

    private static func lookupEntry(in dict: [UUID: Entry], id: UUID, key: Key, now: Date) -> [String]? {
        guard let entry = dict[id],
              entry.key == key,
              now.timeIntervalSince(entry.computedAt) < ttl
        else { return nil }
        return entry.value
    }

    private static func storeEntry(in dict: inout [UUID: Entry], id: UUID, key: Key, value: [String], now: Date) {
        if dict.count >= maxEntries, dict[id] == nil {
            dict = dict.filter { now.timeIntervalSince($0.value.computedAt) < ttl }
            if dict.count >= maxEntries {
                // Everything is fresh (only plausible under pathological row
                // churn) — evict the oldest half so the cap actually bounds
                // the dict instead of growing one entry per new id.
                let oldestFirst = dict.sorted { $0.value.computedAt < $1.value.computedAt }
                for (evictId, _) in oldestFirst.prefix(maxEntries / 2) {
                    dict.removeValue(forKey: evictId)
                }
            }
        }
        dict[id] = Entry(key: key, value: value, computedAt: now)
    }
}

/// MainActor snapshot of "latest Codex activity timestamp per workspace"
/// derived from Codex's own `~/.codex/state_5.sqlite` thread index.
/// Runtime hook status timestamps still win when present; this fills the
/// restored/cleared-status gap without scanning rollout JSONLs from SwiftUI.
@MainActor
final class CasperCodexActivityStore: ObservableObject {
    static let shared = CasperCodexActivityStore()

    @Published private(set) var latestActivityByWorkspace: [UUID: Date] = [:]
    @Published private(set) var latestActivityByPanel: [UUID: Date] = [:]

    private let refreshQueue = DispatchQueue(
        label: "casper.codex-activity.refresh",
        qos: .utility
    )
    private var inFlightWorkspaces: Set<UUID> = []
    private var inFlightPanels: Set<UUID> = []

    func latestActivity(forWorkspaceID id: UUID) -> Date? {
        latestActivityByWorkspace[id]
    }

    func latestActivity(forPanelID id: UUID) -> Date? {
        latestActivityByPanel[id]
    }

    func refresh(workspaceSessions: [UUID: [String]], panelSessions: [UUID: [String]] = [:]) {
        var toRefresh: [UUID: [String]] = [:]
        for (id, sessions) in workspaceSessions {
            if inFlightWorkspaces.contains(id) { continue }
            inFlightWorkspaces.insert(id)
            toRefresh[id] = sessions
        }
        var panelsToRefresh: [UUID: [String]] = [:]
        for (id, sessions) in panelSessions {
            if inFlightPanels.contains(id) { continue }
            inFlightPanels.insert(id)
            panelsToRefresh[id] = sessions
        }
        #if DEBUG
        cmuxDebugLog(
            "casper.codexActivity.refresh.request asked=\(workspaceSessions.count) toRefresh=\(toRefresh.count) panels=\(panelsToRefresh.count)"
        )
        #endif
        guard !toRefresh.isEmpty || !panelsToRefresh.isEmpty else { return }

        var merged: [UUID: [String]] = toRefresh
        for (id, sessions) in panelsToRefresh { merged[id] = sessions }
        refreshQueue.async { [weak self] in
            let start = Date()
            let allResults = CasperCodexActivityIO.computeActivities(forWorkspaceSessions: merged)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            #if DEBUG
            let withDate = allResults.values.compactMap { $0 }.count
            cmuxDebugLog(
                "casper.codexActivity.refresh.compute ws=\(toRefresh.count) panels=\(panelsToRefresh.count) withDate=\(withDate) elapsedMs=\(elapsedMs)"
            )
            #endif
            Task { @MainActor [weak self] in
                if let strong = self {
                    for id in toRefresh.keys { strong.inFlightWorkspaces.remove(id) }
                    for id in panelsToRefresh.keys { strong.inFlightPanels.remove(id) }
                }
                guard let self else { return }
                var wsSnapshot = self.latestActivityByWorkspace
                var panelSnapshot = self.latestActivityByPanel
                var wsChanged = false
                var panelChanged = false
                for (id, date) in allResults {
                    guard let date else { continue }
                    if toRefresh[id] != nil, wsSnapshot[id] != date {
                        wsSnapshot[id] = date
                        wsChanged = true
                    }
                    if panelsToRefresh[id] != nil, panelSnapshot[id] != date {
                        panelSnapshot[id] = date
                        panelChanged = true
                    }
                }
                if wsChanged {
                    self.latestActivityByWorkspace = wsSnapshot
                }
                if panelChanged {
                    self.latestActivityByPanel = panelSnapshot
                }
                #if DEBUG
                cmuxDebugLog(
                    "casper.codexActivity.refresh.publish wsChanged=\(wsChanged) panelChanged=\(panelChanged) storeCount=\(self.latestActivityByWorkspace.count)"
                )
                #endif
            }
        }
    }
}

enum CasperCodexActivityIO {
    static func computeActivities(
        forWorkspaceSessions sessions: [UUID: [String]]
    ) -> [UUID: Date?] {
        guard !sessions.isEmpty else { return [:] }
        var groups: [[String]: [UUID]] = [:]
        var allSessionIDs: Set<String> = []
        for (id, sessionIDs) in sessions {
            let normalized = normalizedSessionIDs(sessionIDs)
            groups[normalized, default: []].append(id)
            for sessionID in normalized { allSessionIDs.insert(sessionID) }
        }
        let dateBySessionID = latestDatesBySessionID(sessionIDs: Array(allSessionIDs))
        var out: [UUID: Date?] = [:]
        out.reserveCapacity(sessions.count)
        for (sessionIDs, ids) in groups {
            let date = sessionIDs.compactMap { dateBySessionID[$0] }.max()
            for id in ids { out[id] = date }
        }
        return out
    }

    private static func normalizedSessionIDs(_ ids: [String]) -> [String] {
        Array(Set(ids.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted()
    }

    private static func latestDatesBySessionID(sessionIDs: [String]) -> [String: Date] {
        let normalized = normalizedSessionIDs(sessionIDs)
        guard !normalized.isEmpty,
              let snapshot = CodexStateDatabaseSnapshot.make()
        else { return [:] }
        defer { snapshot.remove() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ",")
        let sql = """
            SELECT id, updated_at_ms
            FROM threads
            WHERE archived = 0 AND id IN (\(placeholders))
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        for (index, sessionID) in normalized.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), sessionID, -1, SQLITE_TRANSIENT_FN)
        }

        var out: [String: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let sessionID = String(cString: cString)
            let updatedMs = sqlite3_column_int64(stmt, 1)
            guard updatedMs > 0 else { continue }
            out[sessionID] = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
        }
        return out
    }

    private struct CodexStateDatabaseSnapshot {
        let databaseURL: URL
        private let directoryURL: URL

        static func make(
            sourcePath: String = ("~/.codex/state_5.sqlite" as NSString).expandingTildeInPath
        ) -> CodexStateDatabaseSnapshot? {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: sourcePath) else { return nil }
            let snapshotDir = fileManager.temporaryDirectory.appendingPathComponent(
                "cmux-codex-activity-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                let snapshotDB = snapshotDir.appendingPathComponent("state.db")
                try fileManager.copyItem(atPath: sourcePath, toPath: snapshotDB.path)
                for sidecar in ["-wal", "-shm"] {
                    let source = sourcePath + sidecar
                    let destination = snapshotDB.path + sidecar
                    if fileManager.fileExists(atPath: source) {
                        try? fileManager.copyItem(atPath: source, toPath: destination)
                    }
                }
                return CodexStateDatabaseSnapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
            } catch {
                try? fileManager.removeItem(at: snapshotDir)
                return nil
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}

/// MainActor snapshot of "latest real-activity timestamp per workspace"
/// derived from each workspace's recorded Claude Code JSONL session files.
/// Reads are pure dict lookups; refreshes are dispatched to a background
/// queue (the previous implementation walked the filesystem and ran
/// `String.split` on multi-KB JSONL text on the main thread inside a sort
/// comparator, which produced 6+ second startup hangs — see
/// `MainThreadHangWatchdog` and the casper session-restore stack dump).
///
/// The store is observable so the sidebar (which precomputes per-workspace
/// activity before sorting) re-renders when new dates arrive. Row subtrees
/// must NOT hold a reference to this store — they read activity through
/// the snapshot-bundle the sidebar already passes down.
@MainActor
final class CasperClaudeActivityStore: ObservableObject {
    static let shared = CasperClaudeActivityStore()

    @Published private(set) var latestActivityByWorkspace: [UUID: Date] = [:]
    @Published private(set) var latestActivityByPanel: [UUID: Date] = [:]
    /// Path-keyed dates from every scan (and the disk cache). Workspace and
    /// panel UUIDs are minted fresh on each session restore, so only this map
    /// can answer "when was this session last active" across a relaunch.
    @Published private(set) var latestActivityByPath: [String: Date] = [:]

    private let refreshQueue = DispatchQueue(
        label: "casper.claude-activity.refresh",
        qos: .utility
    )
    private var inFlightWorkspaces: Set<UUID> = []
    private var inFlightPanels: Set<UUID> = []
    private var diskSaveScheduled = false

    /// Disk cache so the sidebar can paint times the instant Casper opens —
    /// the off-main JSONL scan still runs and overwrites with fresh values
    /// within ~1s, but the user sees something immediately instead of an
    /// empty trailing column on cold start.
    ///
    /// `-v3` suffix: v1 was poisoned by the cwd-aggregate fallback; v2 fixed
    /// attribution but was keyed by workspace UUID — UUIDs don't survive a
    /// relaunch (session restore mints fresh ones), so v2 could never hit and
    /// the cold-start paint silently never worked. v3 keys by JSONL path,
    /// which is stable across restarts.
    private static let cacheURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cmuxterm/casper-claude-activity-cache-v3.json")
    private static let legacyCacheURLs: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cmuxterm/casper-claude-activity-cache.json"),
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cmuxterm/casper-claude-activity-cache-v2.json"),
    ]

    init() {
        // Disk read + JSON parse runs off-main so the first `.shared`
        // dereference (which happens on the main thread, during sidebar
        // instantiation at app launch) doesn't block. Results merge into
        // `latestActivityByPath` without overwriting any entries the
        // background scan may have already populated by the time we land
        // back on main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for legacy in Self.legacyCacheURLs {
                try? FileManager.default.removeItem(at: legacy)
            }
            let parsed = Self.parseDiskCache()
            guard !parsed.isEmpty else { return }
            Task { @MainActor in
                self?.mergeDiskCache(parsed)
            }
        }
    }

    private func mergeDiskCache(_ parsed: [String: Date]) {
        var merged = latestActivityByPath
        var didMerge = false
        for (path, date) in parsed where merged[path] == nil {
            merged[path] = date
            didMerge = true
        }
        if didMerge {
            // Single @Published assignment so observers get one publish, not
            // one per merged entry.
            latestActivityByPath = merged
            #if DEBUG
            cmuxDebugLog("casper.claudeActivity.cache.load count=\(parsed.count)")
            #endif
        }
    }

    private static func parseDiskCache() -> [String: Date] {
        guard let data = try? Data(contentsOf: cacheURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        var out: [String: Date] = [:]
        out.reserveCapacity(raw.count)
        for (path, value) in raw {
            guard path.hasPrefix("/"),
                  let date = casperISO8601Formatter.date(from: value)
            else { continue }
            out[path] = date
        }
        return out
    }

    private func scheduleDiskSave() {
        if diskSaveScheduled { return }
        diskSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.diskSaveScheduled = false
            let snapshot = self.latestActivityByPath
            DispatchQueue.global(qos: .utility).async {
                Self.persist(snapshot)
            }
        }
    }

    private static func persist(_ dict: [String: Date]) {
        // Keep the on-disk cache bounded — over months of use this dict
        // accumulates an entry per session ever seen; only the
        // most-recently-active matter for cold-start paint.
        let maxPersistedEntries = 200
        let trimmed: [(String, Date)] = dict.count <= maxPersistedEntries
            ? Array(dict)
            : dict.sorted { $0.value > $1.value }.prefix(maxPersistedEntries).map { ($0.key, $0.value) }
        var raw: [String: String] = [:]
        raw.reserveCapacity(trimmed.count)
        for (path, date) in trimmed {
            raw[path] = casperISO8601Formatter.string(from: date)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        let url = cacheURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Pure lookup — never touches the filesystem.
    func latestActivity(forWorkspaceID id: UUID) -> Date? {
        latestActivityByWorkspace[id]
    }

    func latestActivity(forPanelID id: UUID) -> Date? {
        latestActivityByPanel[id]
    }

    /// Path-keyed lookup for callers whose UUID isn't in the runtime maps yet
    /// (cold start before the first scan lands). Pure dict reads.
    func latestActivity(forJSONLPaths paths: [String]) -> Date? {
        paths.compactMap { latestActivityByPath[$0] }.max()
    }

    /// Kicks off a background scan for the given workspace → JSONL-paths map.
    /// Cadence is the caller's responsibility (the sidebar `.task` loop polls
    /// every 20s so resumes that reuse the same sessionId — JSONL grows, path
    /// set unchanged — still surface). The in-flight gate coalesces redundant
    /// calls into a single scan. Safe to call from `onAppear` / `.task(id:)`
    /// — never from `body` (would feed back through @Published).
    func refresh(workspaceSessions: [UUID: [String]], panelSessions: [UUID: [String]] = [:]) {
        var toRefresh: [UUID: [String]] = [:]
        for (id, paths) in workspaceSessions {
            if inFlightWorkspaces.contains(id) { continue }
            inFlightWorkspaces.insert(id)
            toRefresh[id] = paths
        }
        var panelsToRefresh: [UUID: [String]] = [:]
        // Separate in-flight namespace from workspaces: sharing one set meant
        // a (theoretical) workspace/panel UUID coincidence silently dropped
        // the panel's refresh, and structurally invited bugs if the key
        // spaces ever overlap (e.g. a future refactor keying single-panel
        // workspaces by panel ID).
        for (id, paths) in panelSessions {
            if inFlightPanels.contains(id) { continue }
            inFlightPanels.insert(id)
            panelsToRefresh[id] = paths
        }
        #if DEBUG
        cmuxDebugLog(
            "casper.claudeActivity.refresh.request asked=\(workspaceSessions.count) toRefresh=\(toRefresh.count) panels=\(panelsToRefresh.count)"
        )
        #endif
        guard !toRefresh.isEmpty || !panelsToRefresh.isEmpty else { return }
        // Merge into a single compute call so the dedup-by-path-set inside
        // CasperClaudeActivityIO coalesces JSONLs that appear in both a
        // workspace's path list and one of its panels' path lists (the
        // common case for multi-panel workspaces). Workspace and panel IDs
        // come from independent UUID v4 pools, so no key collisions.
        var merged: [UUID: [String]] = toRefresh
        for (id, paths) in panelsToRefresh { merged[id] = paths }
        refreshQueue.async { [weak self] in
            let start = Date()
            let scan = CasperClaudeActivityIO.computeActivities(forWorkspaceSessions: merged)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            #if DEBUG
            let withDate = scan.byRequestID.values.compactMap { $0 }.count
            cmuxDebugLog(
                "casper.claudeActivity.refresh.compute ws=\(toRefresh.count) panels=\(panelsToRefresh.count) withDate=\(withDate) elapsedMs=\(elapsedMs)"
            )
            #endif
            Task { @MainActor [weak self] in
                // Drop the in-flight gate BEFORE the self-guard so a torn-down
                // store doesn't permanently wedge these IDs.
                if let strong = self {
                    for id in toRefresh.keys { strong.inFlightWorkspaces.remove(id) }
                    for id in panelsToRefresh.keys { strong.inFlightPanels.remove(id) }
                }
                guard let self else { return }
                var wsSnapshot = self.latestActivityByWorkspace
                var panelSnapshot = self.latestActivityByPanel
                var wsChanged = false
                var panelChanged = false
                for (id, date) in scan.byRequestID {
                    guard let date else { continue }
                    if toRefresh[id] != nil, wsSnapshot[id] != date {
                        wsSnapshot[id] = date
                        wsChanged = true
                    }
                    if panelsToRefresh[id] != nil, panelSnapshot[id] != date {
                        panelSnapshot[id] = date
                        panelChanged = true
                    }
                }
                if wsChanged {
                    self.latestActivityByWorkspace = wsSnapshot
                }
                if panelChanged {
                    self.latestActivityByPanel = panelSnapshot
                }
                // Path-keyed dates back the cold-start disk cache and the
                // UUID-miss lookup fallback; fresh scan values win.
                var pathSnapshot = self.latestActivityByPath
                var pathChanged = false
                for (path, date) in scan.datesByPath where pathSnapshot[path] != date {
                    pathSnapshot[path] = date
                    pathChanged = true
                }
                if pathChanged {
                    self.latestActivityByPath = pathSnapshot
                    self.scheduleDiskSave()
                }
                #if DEBUG
                cmuxDebugLog(
                    "casper.claudeActivity.refresh.publish wsChanged=\(wsChanged) panelChanged=\(panelChanged) pathChanged=\(pathChanged) storeCount=\(self.latestActivityByWorkspace.count)"
                )
                #endif
            }
        }
    }
}

/// Background-only filesystem walker. NEVER call from main — every public
/// entry point is documented as background-only.
enum CasperClaudeActivityIO {
    struct ScanResult {
        /// Per requested workspace/panel id; nil means "no JSONLs found or no
        /// parseable activity".
        let byRequestID: [UUID: Date?]
        /// Per distinct JSONL path with parseable activity — feeds the
        /// path-keyed cold-start disk cache.
        let datesByPath: [String: Date]
    }

    /// Background-only. Caller must dispatch back to main for cache updates.
    /// Each distinct path is scanned once, concurrently — for users with many
    /// open workspaces, sequential 50ms-per-file IO compounds into a visible
    /// cold-open delay — and every requested id takes the max over its paths.
    static func computeActivities(
        forWorkspaceSessions sessions: [UUID: [String]]
    ) -> ScanResult {
        guard !sessions.isEmpty else { return ScanResult(byRequestID: [:], datesByPath: [:]) }
        // Dedup by path (not by identical path *set*): overlapping sets — a
        // workspace's list and its panels' sublists — still read each file
        // exactly once per poll.
        let distinctPaths = Array(Set(sessions.values.flatMap { $0 }))
        var dateByIndex = Array<Date?>(repeating: nil, count: distinctPaths.count)
        dateByIndex.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: distinctPaths.count) { i in
                buf[i] = latestRealActivity(forJSONLPath: distinctPaths[i])
            }
        }
        var datesByPath: [String: Date] = [:]
        datesByPath.reserveCapacity(distinctPaths.count)
        for (i, path) in distinctPaths.enumerated() {
            if let date = dateByIndex[i] { datesByPath[path] = date }
        }
        var out: [UUID: Date?] = [:]
        out.reserveCapacity(sessions.count)
        for (id, paths) in sessions {
            out[id] = paths.compactMap { datesByPath[$0] }.max()
        }
        #if DEBUG
        let missCount = out.values.filter { $0 == nil }.count
        if missCount > 0 {
            cmuxDebugLog(
                "casper.claudeActivity.miss ids=\(missCount) distinctPaths=\(distinctPaths.count)"
            )
        }
        #endif
        return ScanResult(byRequestID: out, datesByPath: datesByPath)
    }

    /// Returns the latest `timestamp` on a real user/assistant message in the
    /// given JSONL, skipping `/resume`-style metadata records (no timestamp)
    /// and `/compact` summary turns. Reads only the file's tail to avoid
    /// loading multi-MB sessions in full.
    private static func latestRealActivity(forJSONLPath path: String) -> Date? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)
        else { return nil }
        // JSONLs are append-only; (size, mtime) is a tight cache key. Skips
        // the 256KB tail read + grapheme scan on every 20s poll for files
        // that haven't changed since we last parsed them.
        if let cached = LatestActivityCache.lookup(path: path, size: size, mtime: mtime) {
            return cached
        }
        let parsed = parseLatestRealActivity(path: path, size: size)
        LatestActivityCache.store(path: path, size: size, mtime: mtime, value: parsed)
        return parsed
    }

    /// Thread-safe cache keyed on (path, size, mtime). Reads/writes happen
    /// from `computeActivities`' `DispatchQueue.concurrentPerform`, so the
    /// lock is required.
    private enum LatestActivityCache {
        private struct Entry {
            let size: Int64
            let mtime: Date
            let value: Date?
        }
        private static var entries: [String: Entry] = [:]
        private static let lock = NSLock()
        private static let maxEntries = 1024

        static func lookup(path: String, size: Int64, mtime: Date) -> Date?? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[path], e.size == size, e.mtime == mtime else {
                return nil
            }
            return .some(e.value)
        }

        static func store(path: String, size: Int64, mtime: Date, value: Date?) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= maxEntries, entries[path] == nil {
                // Drop oldest-mtime entries to keep the cache bounded. A
                // simple half-size sweep is cheap and rare.
                let kept = entries
                    .sorted { $0.value.mtime > $1.value.mtime }
                    .prefix(maxEntries / 2)
                entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
            entries[path] = Entry(size: size, mtime: mtime, value: value)
        }
    }

    private static func parseLatestRealActivity(path: String, size: Int64) -> Date? {
        // Read at most the last 256KB. `/resume` appends ~a few KB of
        // metadata; the real-activity message we want is typically within
        // the trailing handful of lines.
        let maxTail: Int64 = 256 * 1024
        let offset = max(0, size - maxTail)
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Byte-level newline scan — `String.split` over a 256KB Swift String
        // pays grapheme-iteration cost per byte, which is too expensive here.
        var lineRanges: [Range<Int>] = []
        let count = data.count
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var lineStart = 0
            for i in 0..<count {
                if base[i] == 0x0A {
                    if i > lineStart { lineRanges.append(lineStart..<i) }
                    lineStart = i + 1
                }
            }
            if lineStart < count { lineRanges.append(lineStart..<count) }
        }
        // Skip the first line if we didn't start at offset 0 — it's probably
        // a partial line cut by the seek.
        let startIdx = offset == 0 ? 0 : 1
        guard lineRanges.count > startIdx else { return nil }
        for range in lineRanges[startIdx...].reversed() {
            let line = data.subdata(in: range)
            guard let date = realActivityDate(fromJSONLData: line) else { continue }
            return date
        }
        return nil
    }

    private static func realActivityDate(fromJSONLData data: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { return nil }
        if obj["isCompactSummary"] as? Bool == true { return nil }
        if obj["isMeta"] as? Bool == true { return nil }
        if obj["isSnapshotUpdate"] as? Bool == true { return nil }
        guard let ts = obj["timestamp"] as? String else { return nil }
        return casperISO8601Formatter.date(from: ts)
    }
}
