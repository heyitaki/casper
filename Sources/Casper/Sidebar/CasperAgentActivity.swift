// CASPER: per-workspace agent activity state derived from cmux's existing
// hook-driven `Workspace.statusEntries` (set by `cmux hooks <agent> *` from
// Resources/bin/{claude,codex}). Maps the cmux status entries to a 4-state
// model (working / needsInput / done / none) that the compact sidebar row
// renders. Delete if upstream adds a first-class agent-state surface on
// Workspace.

import Foundation
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
        let agentEntries = workspace.statusEntries.compactMap { key, entry -> SidebarStatusEntry? in
            agentStatusKeys.contains(key.lowercased()) ? entry : nil
        }

        // WORKING / NEEDS_INPUT only fire when cmux's hook system has live
        // agent state. Working wins over everything; needs-input includes
        // unread notifications even if the agent entry says Idle.
        if agentEntries.contains(where: isWorkingValue) {
            return CasperWorkspaceActivity(
                state: .working,
                lastActivityAt: agentEntries.map(\.timestamp).max()
            )
        }
        let unreadCount = notificationStore.unreadCount(forTabId: workspace.id)
        if agentEntries.contains(where: isNeedsInputValue) || (unreadCount > 0 && !agentEntries.isEmpty) {
            let agentMax = agentEntries.map(\.timestamp).max()
            let notifDate = notificationStore.latestNotification(forTabId: workspace.id)?.createdAt
            let lastActivityAt = [agentMax, notifDate].compactMap { $0 }.max()
            return CasperWorkspaceActivity(state: .needsInput, lastActivityAt: lastActivityAt)
        }

        // DONE: real user-visible activity only. We deliberately exclude
        // `workspace.logEntries.last?.timestamp` even though it has a
        // timestamp — `appendSidebarLog` fires `Date()` for system events
        // like port-conflict warnings during terminal reconnect, which pegs
        // every restored workspace to "<1m" the moment they come back. Same
        // category as `/resume` / `/compact`: not real user activity.
        //
        // Claude JSONL is the per-workspace fallback (parsed off-main into
        // `CasperClaudeActivityStore`) — finds the latest real user/assistant
        // message timestamp in `~/.claude/projects/<dashed-cwd>/*.jsonl`,
        // skipping metadata-only resume records and compact-summary turns.
        let agentMax = agentEntries.map(\.timestamp).max()
        let notifDate = notificationStore.latestNotification(forTabId: workspace.id)?.createdAt
        let claudeDate = claudeActivityDate(for: workspace)
        let candidates = [agentMax, notifDate, claudeDate].compactMap { $0 }
        if let lastActivityAt = candidates.max() {
            return CasperWorkspaceActivity(state: .done, lastActivityAt: lastActivityAt)
        }
        return CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
    }

    /// Pure snapshot read against `CasperClaudeActivityStore` — no I/O. The
    /// store is refreshed off-main by the sidebar whenever the visible
    /// workspaces' JSONL path set changes.
    private static func claudeActivityDate(for workspace: Workspace) -> Date? {
        CasperClaudeActivityStore.shared.latestActivity(forWorkspaceID: workspace.id)
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
    /// Paths are sorted so identical sets hash identically for the activity
    /// store's per-path-set dedup.
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

    /// Session-attributed fallback paths used when the live hook map has no
    /// record for this workspace — typically because the workspace was
    /// restored from session persistence and Claude hasn't relaunched yet.
    /// Returns `[]` when there are no claude snapshots: the caller treats
    /// that as "no attribution available" and surfaces no trailing time
    /// rather than risk a misleading aggregate across siblings.
    private static func claudeSnapshotJSONLPaths(for workspace: Workspace) -> [String] {
        let home = NSHomeDirectory() as NSString
        // Dedup so two panels sharing the same `(sessionId, cwd)` produce one
        // path — keeps the activity store's per-path-set grouping aligned with
        // single-panel workspaces pointing at the same JSONL.
        var paths: Set<String> = []
        for (sid, cwd) in validClaudeSnapshots(for: workspace) {
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            paths.insert(home.appendingPathComponent(".claude/projects/\(encoded)/\(sid).jsonl"))
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
        return CachedState(mtime: mtime, map: parse(path: path))
    }

    private static func parse(path: String) -> [UUID: [String]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: [String: Any]]
        else { return [:] }
        let home = NSHomeDirectory() as NSString
        var out: [UUID: [String]] = [:]
        for (sessionId, record) in sessions {
            guard let workspaceIdString = record["workspaceId"] as? String,
                  let workspaceId = UUID(uuidString: workspaceIdString),
                  let cwd = record["cwd"] as? String
            else { continue }
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            let jsonlPath = home
                .appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl")
            out[workspaceId, default: []].append(jsonlPath)
        }
        return out
    }
}

/// Cheap, stable id for `VerticalTabsSidebar`'s Claude-activity poll task.
/// Hashing the full `[UUID: [String]]` of per-workspace JSONL paths on
/// every body eval costs hundreds of string hashes; this two-field id
/// captures the only inputs that should restart the poll loop.
struct CasperClaudeSessionsTaskID: Hashable {
    let mapVersion: TimeInterval
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
        guard let entry = entries[workspaceId],
              entry.key == key,
              now.timeIntervalSince(entry.computedAt) < ttl
        else { return nil }
        return entry.value
    }

    static func store(workspaceId: UUID, key: Key, value: [String], now: Date) {
        if entries.count >= maxEntries, entries[workspaceId] == nil {
            entries = entries.filter { now.timeIntervalSince($0.value.computedAt) < ttl }
        }
        entries[workspaceId] = Entry(key: key, value: value, computedAt: now)
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

    private let refreshQueue = DispatchQueue(
        label: "casper.claude-activity.refresh",
        qos: .utility
    )
    private var inFlightWorkspaces: Set<UUID> = []
    private var diskSaveScheduled = false

    /// Disk cache so the sidebar can paint times the instant Casper opens —
    /// the off-main JSONL scan still runs and overwrites with fresh values
    /// within ~1s, but the user sees something immediately instead of an
    /// empty trailing column on cold start.
    ///
    /// `-v2` suffix: the v1 cache was populated by the cwd-aggregate fallback
    /// in `computeClaudeJSONLPaths`, which leaked the most-recently-active
    /// sibling session's timestamp to every workspace sharing a project root.
    /// Renaming the file ensures the first cold start after the per-session
    /// attribution fix paints from a fresh scan rather than the stale v1 map.
    private static let cacheURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cmuxterm/casper-claude-activity-cache-v2.json")

    init() {
        // Disk read + JSON parse runs off-main so the first `.shared`
        // dereference (which happens on the main thread, during sidebar
        // instantiation at app launch) doesn't block. Results merge into
        // `latestActivityByWorkspace` without overwriting any entries the
        // background scan may have already populated by the time we land
        // back on main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let parsed = Self.parseDiskCache()
            guard !parsed.isEmpty else { return }
            Task { @MainActor in
                self?.mergeDiskCache(parsed)
            }
        }
    }

    private func mergeDiskCache(_ parsed: [UUID: Date]) {
        var merged = latestActivityByWorkspace
        var didMerge = false
        for (id, date) in parsed where merged[id] == nil {
            merged[id] = date
            didMerge = true
        }
        if didMerge {
            // Single @Published assignment so observers get one publish, not
            // one per merged entry.
            latestActivityByWorkspace = merged
            #if DEBUG
            cmuxDebugLog("casper.claudeActivity.cache.load count=\(parsed.count)")
            #endif
        }
    }

    private static func parseDiskCache() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: cacheURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        var out: [UUID: Date] = [:]
        out.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let id = UUID(uuidString: key),
                  let date = casperISO8601Formatter.date(from: value)
            else { continue }
            out[id] = date
        }
        return out
    }

    private func scheduleDiskSave() {
        if diskSaveScheduled { return }
        diskSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.diskSaveScheduled = false
            let snapshot = self.latestActivityByWorkspace
            DispatchQueue.global(qos: .utility).async {
                Self.persist(snapshot)
            }
        }
    }

    private static func persist(_ dict: [UUID: Date]) {
        // Keep the on-disk cache bounded — over months of use this dict
        // accumulates an entry per workspace ever seen across forks; only the
        // most-recently-active matter for cold-start paint.
        let maxPersistedEntries = 200
        let trimmed: [(UUID, Date)] = dict.count <= maxPersistedEntries
            ? Array(dict)
            : dict.sorted { $0.value > $1.value }.prefix(maxPersistedEntries).map { ($0.key, $0.value) }
        var raw: [String: String] = [:]
        raw.reserveCapacity(trimmed.count)
        for (id, date) in trimmed {
            raw[id.uuidString] = casperISO8601Formatter.string(from: date)
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

    /// Kicks off a background scan for the given workspace → JSONL-paths map.
    /// Cadence is the caller's responsibility (the sidebar `.task` loop polls
    /// every 20s so resumes that reuse the same sessionId — JSONL grows, path
    /// set unchanged — still surface). The in-flight gate coalesces redundant
    /// calls into a single scan. Safe to call from `onAppear` / `.task(id:)`
    /// — never from `body` (would feed back through @Published).
    func refresh(workspaceSessions: [UUID: [String]]) {
        var toRefresh: [UUID: [String]] = [:]
        for (id, paths) in workspaceSessions {
            if inFlightWorkspaces.contains(id) { continue }
            inFlightWorkspaces.insert(id)
            toRefresh[id] = paths
        }
        #if DEBUG
        cmuxDebugLog(
            "casper.claudeActivity.refresh.request asked=\(workspaceSessions.count) toRefresh=\(toRefresh.count)"
        )
        #endif
        guard !toRefresh.isEmpty else { return }
        refreshQueue.async { [weak self] in
            let start = Date()
            let results = CasperClaudeActivityIO.computeActivities(forWorkspaceSessions: toRefresh)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            #if DEBUG
            let withDate = results.values.compactMap { $0 }.count
            cmuxDebugLog(
                "casper.claudeActivity.refresh.compute count=\(toRefresh.count) withDate=\(withDate) elapsedMs=\(elapsedMs)"
            )
            #endif
            Task { @MainActor [weak self] in
                // Drop the in-flight gate BEFORE the self-guard so a torn-down
                // store doesn't permanently wedge these IDs. The store is a
                // singleton today, but the gate is what makes a future
                // non-singleton split (per-window store) safe to add.
                if let strong = self {
                    for id in toRefresh.keys { strong.inFlightWorkspaces.remove(id) }
                }
                guard let self else { return }
                // Stage mutations into a local copy and assign back ONCE.
                // Mutating `self.latestActivityByWorkspace[id]` per entry fires
                // `objectWillChange` per write — at 50 workspaces all returning
                // new dates from a single poll, that's 50 synchronous publish
                // calls before the loop ends. SwiftUI coalesces into one body
                // re-eval, but the publish-storm is still wasted CPU on the
                // hot main-thread loop. One assignment = one publish.
                //
                // Cross-scan key preservation: this snapshot-then-assign-once
                // pattern relies on `refreshQueue` being serial and the
                // MainActor task hops landing in dispatch order. Both are true
                // — do not switch `refreshQueue` to `.concurrent` without
                // adding a per-key merge here.
                var snapshot = self.latestActivityByWorkspace
                var changed = false
                for (id, date) in results {
                    // nil result means "no parseable activity found this
                    // scan" — could be a transient miss (tail is all compact
                    // summaries, file briefly locked). Leave any previously
                    // known date in place so the sidebar doesn't blank out.
                    guard let date else { continue }
                    if snapshot[id] != date {
                        snapshot[id] = date
                        changed = true
                    }
                }
                // Single publish + disk-save when (and only when) at least one
                // workspace's date changed. Skipping the publish on a no-op
                // scan is the whole point: the row's relative-time text
                // updates via TimelineView, and TabItemView.Equatable forces
                // a re-render whenever a date actually changes — so a
                // best-effort publish here would only trigger wasted sidebar
                // body re-evals (which re-walk all the JSONL-path stats).
                if changed {
                    self.latestActivityByWorkspace = snapshot
                    self.scheduleDiskSave()
                }
                #if DEBUG
                cmuxDebugLog(
                    "casper.claudeActivity.refresh.publish changed=\(changed) storeCount=\(self.latestActivityByWorkspace.count)"
                )
                #endif
            }
        }
    }
}

/// Background-only filesystem walker. NEVER call from main — every public
/// entry point is documented as background-only.
enum CasperClaudeActivityIO {
    /// Background-only. Returns `[workspaceID: Date?]` where nil means "no
    /// JSONLs found or no parseable activity". Caller must dispatch back to
    /// main for cache updates. Scans workspaces concurrently — for users
    /// with many open workspaces, sequential 50ms-per-file IO compounds into
    /// a visible cold-open delay.
    static func computeActivities(
        forWorkspaceSessions sessions: [UUID: [String]]
    ) -> [UUID: Date?] {
        guard !sessions.isEmpty else { return [:] }
        // Group workspaces by identical path list. The cwd fallback often
        // resolves many workspaces to the same project-dir JSONL set; without
        // dedup that's N×M file reads per poll.
        var groups: [[String]: [UUID]] = [:]
        for (id, paths) in sessions {
            groups[paths, default: []].append(id)
        }
        let distinct = Array(groups.keys)
        var dateByPaths = Array<Date?>(repeating: nil, count: distinct.count)
        dateByPaths.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: distinct.count) { i in
                buf[i] = computeLatestActivity(forJSONLPaths: distinct[i])
            }
        }
        var out: [UUID: Date?] = [:]
        out.reserveCapacity(sessions.count)
        for (i, paths) in distinct.enumerated() {
            let date = dateByPaths[i]
            guard let ids = groups[paths] else { continue }
            #if DEBUG
            if date == nil {
                cmuxDebugLog(
                    "casper.claudeActivity.miss workspaces=\(ids.count) paths=\(paths.count)"
                )
            }
            #endif
            for id in ids { out[id] = date }
        }
        return out
    }

    private static func computeLatestActivity(forJSONLPaths paths: [String]) -> Date? {
        var latest: Date?
        for path in paths {
            guard let activity = latestRealActivity(forJSONLPath: path) else { continue }
            if latest == nil || activity > latest! { latest = activity }
        }
        return latest
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
