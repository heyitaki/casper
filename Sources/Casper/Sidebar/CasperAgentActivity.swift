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

    /// JSONL paths to scan for this workspace's last activity:
    /// 1. Prefer the hook records (per-session attribution via
    ///    `~/.cmuxterm/claude-hook-sessions.json`).
    /// 2. Fall back to every `*.jsonl` in `~/.claude/projects/<encoded-cwd>/`
    ///    for each cwd the workspace knows about (currentDirectory + every
    ///    panel directory). Workspaces sharing a cwd in this fallback path
    ///    will all see the same time — `CasperClaudeActivityIO` dedupes
    ///    identical path sets so the JSONLs are only read once per refresh.
    /// Paths are sorted so identical sets hash identically for that dedup.
    static func claudeJSONLPaths(
        for workspace: Workspace,
        localWorkspaceIDs: Set<UUID>
    ) -> [String] {
        let hookPaths = CasperClaudeSessionMap.shared.jsonlPaths(forWorkspaceID: workspace.id)
        if !hookPaths.isEmpty { return hookPaths.sorted() }
        // Cwd fallback is only safe when this workspace has actually had an
        // agent — otherwise a fresh workspace defaulting to ~/code/cmux would
        // inherit the newest non-live JSONL in that project dir (e.g. "2d")
        // even though no agent ever ran here.
        let hasAgentEvidence = !workspace.agentPIDs.isEmpty
            || !workspace.restoredAgentSnapshotsByPanelId.isEmpty
        guard hasAgentEvidence else { return [] }
        var cwds: Set<String> = []
        let trimmedCurrent = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCurrent.isEmpty { cwds.insert(trimmedCurrent) }
        for dir in workspace.panelDirectories.values {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { cwds.insert(trimmed) }
        }
        // Exclude (a) JSONLs claimed by another *local* workspace's hook
        // record — those belong to that sibling, not this one — and (b)
        // JSONLs currently being written (mtime within last 120s, i.e. "live"
        // sessions like the user's current Claude conversation). Without (b)
        // every shared-cwd workspace inherits the live session's "<1m"
        // timestamp. 120s balances "ongoing turn pause" against the inverse
        // regression where a workspace's own just-finished JSONL gets
        // suppressed for the full cutoff when its hook record was already
        // consumed.
        //
        // Scoping to *local* IDs matters because the hook file is shared
        // across bundle IDs (Casper Preview / pinned Casper / dev cmux); a
        // record for some other app's workspace must not hide a JSONL that
        // this app has no other way to surface.
        let claimed = CasperClaudeSessionMap.shared
            .claimedJSONLPaths(forLocalWorkspaceIDs: localWorkspaceIDs)
        let now = Date()
        let liveCutoff: TimeInterval = 120
        var allPaths: [String] = []
        for cwd in cwds {
            for path in CasperClaudeProjectDirMap.shared.jsonlPaths(forCwd: cwd) {
                if claimed.contains(path) { continue }
                if let mtime = CasperFileMtimeCache.mtime(for: path, now: now),
                   now.timeIntervalSince(mtime) < liveCutoff {
                    continue
                }
                allPaths.append(path)
            }
        }
        return allPaths.sorted()
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
final class CasperClaudeSessionMap {
    static let shared = CasperClaudeSessionMap()

    private struct CachedState {
        let mtime: Date
        let map: [UUID: [String]]
    }

    private var cached: CachedState?
    private var lastCheckedAt: Date = .distantPast
    /// Skip the hook-file stat on repeat reads within this window. At N=50
    /// workspaces with no hook records, `claudeJSONLPaths(for:)` would
    /// otherwise stat this file 100× per sidebar body re-eval (twice per
    /// workspace, via the `jsonlPaths(forWorkspaceID:)` +
    /// `claimedJSONLPaths(forLocalWorkspaceIDs:)` pair). 2s is short enough
    /// that a freshly registered session shows up almost immediately.
    private let stalenessCheckTTL: TimeInterval = 2.0

    func jsonlPaths(forWorkspaceID id: UUID) -> [String] {
        refreshIfStale()
        return cached?.map[id] ?? []
    }

    /// Paths claimed by the given set of *local* workspaces' hook records.
    /// The cwd fallback uses this to skip JSONLs that already belong to a
    /// known local workspace — without it, that workspace's session timestamp
    /// leaks into every sibling sharing the same cwd.
    ///
    /// Scoped to local IDs because `~/.cmuxterm/claude-hook-sessions.json` is
    /// shared across bundle IDs (Casper Preview, pinned Casper, dev cmux all
    /// write to it). Records for workspaces in other apps must not suppress
    /// this app's fallback candidates — those workspace UUIDs don't exist
    /// here, so we have no way to display the times those records would
    /// otherwise hide.
    func claimedJSONLPaths(forLocalWorkspaceIDs ids: Set<UUID>) -> Set<String> {
        refreshIfStale()
        guard let map = cached?.map, !ids.isEmpty else { return [] }
        var out = Set<String>()
        for id in ids {
            if let paths = map[id] { out.formUnion(paths) }
        }
        return out
    }

    private func refreshIfStale() {
        let now = Date()
        if cached != nil, now.timeIntervalSince(lastCheckedAt) < stalenessCheckTTL { return }
        lastCheckedAt = now
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cmuxterm/claude-hook-sessions.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else {
            cached = nil
            return
        }
        if let cached, cached.mtime == mtime { return }
        cached = CachedState(mtime: mtime, map: Self.parse(path: path))
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

/// Per-file mtime cache with a short TTL. Used by the cwd fallback to
/// avoid stat()-ing every JSONL on every sidebar body re-eval.
@MainActor
enum CasperFileMtimeCache {
    private static var cache: [String: (checkedAt: Date, mtime: Date?)] = [:]
    /// Cap so a long-running app accumulating thousands of seen JSONLs
    /// (months of `~/.claude/projects/*/*.jsonl`) doesn't grow the dict
    /// unboundedly. When the cap trips we drop entries whose `checkedAt`
    /// is older than the TTL — they would re-stat on next access anyway.
    private static let maxEntries = 1024

    static func mtime(for path: String, now: Date = Date(), ttl: TimeInterval = 10) -> Date? {
        if let cached = cache[path], now.timeIntervalSince(cached.checkedAt) < ttl {
            return cached.mtime
        }
        if cache.count >= maxEntries {
            cache = cache.filter { now.timeIntervalSince($0.value.checkedAt) < ttl }
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        cache[path] = (now, mtime)
        return mtime
    }
}

/// Fallback path resolver for workspaces that have no Claude hook record:
/// returns every `*.jsonl` file in `~/.claude/projects/<encoded-cwd>/`.
/// Cached on the project dir's mtime (changes when a JSONL is added/removed
/// — which is what we care about; per-file content changes are handled by
/// the activity store's poll loop).
@MainActor
final class CasperClaudeProjectDirMap {
    static let shared = CasperClaudeProjectDirMap()

    private struct CachedDir {
        let checkedAt: Date
        let mtime: Date
        let paths: [String]
    }
    private var cache: [String: CachedDir] = [:]
    /// Same reason as `CasperClaudeSessionMap.stalenessCheckTTL` — without this
    /// every body re-eval stats `~/.claude/projects/<encoded-cwd>` once per
    /// unique cwd. 2s lets a new JSONL appearing in a project dir surface
    /// within the same poll cycle.
    private let stalenessCheckTTL: TimeInterval = 2.0

    func jsonlPaths(forCwd cwd: String) -> [String] {
        let now = Date()
        if let entry = cache[cwd], now.timeIntervalSince(entry.checkedAt) < stalenessCheckTTL {
            return entry.paths
        }
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let projectDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects/\(encoded)")
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: projectDir),
              let mtime = attrs[.modificationDate] as? Date
        else {
            cache.removeValue(forKey: cwd)
            return []
        }
        if let entry = cache[cwd], entry.mtime == mtime {
            cache[cwd] = CachedDir(checkedAt: now, mtime: entry.mtime, paths: entry.paths)
            return entry.paths
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: projectDir) else {
            return []
        }
        let paths = entries
            .filter { $0.hasSuffix(".jsonl") }
            .map { (projectDir as NSString).appendingPathComponent($0) }
        cache[cwd] = CachedDir(checkedAt: now, mtime: mtime, paths: paths)
        return paths
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
    private static let cacheURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cmuxterm/casper-claude-activity-cache.json")

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
        var raw: [String: String] = [:]
        raw.reserveCapacity(dict.count)
        for (id, date) in dict {
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
                guard let self else { return }
                for id in toRefresh.keys {
                    self.inFlightWorkspaces.remove(id)
                }
                var changed = false
                for (id, date) in results {
                    if let date {
                        if self.latestActivityByWorkspace[id] != date {
                            self.latestActivityByWorkspace[id] = date
                            changed = true
                        }
                    } else if self.latestActivityByWorkspace.removeValue(forKey: id) != nil {
                        changed = true
                    }
                }
                #if DEBUG
                cmuxDebugLog(
                    "casper.claudeActivity.refresh.publish changed=\(changed) storeCount=\(self.latestActivityByWorkspace.count)"
                )
                #endif
                if changed {
                    self.scheduleDiskSave()
                }
                // No-op when nothing changed: the row's relative-time text
                // updates via TimelineView, and TabItemView.Equatable forces
                // a re-render whenever a date actually changes — so a
                // best-effort publish here only triggers wasted sidebar
                // body re-evals (which re-walk all the JSONL-path stats).
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
              let size = (attrs[.size] as? NSNumber)?.int64Value
        else { return nil }
        return parseLatestRealActivity(path: path, size: size)
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

        // Byte-level newline scan. The previous implementation used
        // `String.split(separator: "\n")` over a 256KB Swift String, which
        // pays Character (grapheme) iteration cost for every byte and was
        // the dominant frame in the startup hang (1071/1317 samples).
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
