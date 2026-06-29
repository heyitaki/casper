// CASPER: per-panel sidebar entries grouped by repo path.
//
// History: this file originally produced one sidebar row per workspace.
// Switching panels inside a multi-panel workspace would rewrite the workspace
// title in the sidebar, and concurrent agent sessions in the same workspace
// couldn't be monitored side-by-side. The list is now panel-keyed: every
// terminal/browser/markdown/file-preview panel produces its own row, sorted
// by activity and grouped by the repo root of the panel's own working
// directory.
//
// Delete if upstream adds first-class per-panel rows in the sidebar.

import AppKit
import Foundation
import SwiftUI

// MARK: - Panel sidebar entry

/// Identifies a row in the panel-keyed sidebar. `panelId` alone is unique
/// across the running app, but we carry the workspace id so callers don't
/// have to walk every workspace to resolve actions against the row.
struct CasperSidebarPanelKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}

/// Immutable value snapshot of a single panel for the sidebar. The sidebar
/// builds these from `[Workspace]` once per body re-eval; rows MUST NOT hold
/// a reference to the underlying `Workspace` (snapshot-boundary rule —
/// `Sources/SessionIndexView.swift` for the reference pattern, GH #2586 for
/// the spin-loop incident the rule prevents).
struct CasperSidebarPanelEntry: Identifiable, Equatable, Sendable {
    let key: CasperSidebarPanelKey
    /// Title to render, with the leading agent-activity glyph stripped.
    let displayTitle: String
    /// Raw title before glyph stripping — used for accessibility and the
    /// activity-glyph fallback that other tools rely on.
    let rawTitle: String
    /// Repo-root path computed from this panel's working directory.
    /// Empty when the panel hasn't reported a cwd yet.
    let groupKey: String
    /// True when this entry's workspace is the one currently selected in the
    /// sidebar (drives the chrome's primary highlight).
    let isWorkspaceSelected: Bool
    /// True when this entry's panel is the focused panel inside its
    /// workspace's split tree. Combined with `isWorkspaceSelected` this is
    /// the "selected row" predicate.
    let isPanelFocused: Bool
    /// Mirrors `workspace.isPinned`. Pin remains a workspace-level concept
    /// for v1 — pinning a workspace floats all its panels above the
    /// activity-sorted region.
    let isPinned: Bool
    /// Workspace-level activity. Every panel row in a workspace currently
    /// surfaces the same value; per-panel attribution is the planned
    /// follow-up.
    let activity: CasperWorkspaceActivity
    /// Sort tiebreaker so panels inside the same workspace keep a stable
    /// in-list position when their activity ties (the common case for v1).
    let withinWorkspaceOrder: Int

    var id: UUID { key.panelId }
}

// MARK: - Group model

struct CasperWorkspaceGroup: Identifiable {
    let key: String
    let displayName: String
    let entries: [CasperSidebarPanelEntry]
    var id: String { key }
}

@MainActor
enum CasperWorkspaceGroupResolver {
    // Repo roots don't move during a session, so a process-lifetime cache is fine.
    // Keyed by the directory we resolved from (not by repo root) so a `cd` into a
    // subdir still hits cache after the first walk.
    private static var repoRootCache: [String: String?] = [:]

    // Standardized once at process start so the per-keystroke `groupKey` loop
    // doesn't redo `URL.standardizedFileURL` (a symlink-resolving syscall)
    // for every panel.
    private static let homeKey: String = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

    /// Resolve a single panel's group key from its own working directory,
    /// falling back to the workspace's `currentDirectory` only when the panel
    /// itself hasn't reported a cwd yet (e.g. before its first OSC 7). A
    /// panel in `~` resolves to home — same as before, but per-panel rather
    /// than aggregated across the workspace.
    static func groupKey(forPanel panelId: UUID, in workspace: Workspace) -> String {
        let panelDir = workspace.panelDirectories[panelId]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = panelDir.isEmpty ? fallback : panelDir
        guard !dir.isEmpty else { return "" }
        let raw: String
        if let root = repoRoot(forDirectory: dir) {
            raw = root
        } else {
            raw = URL(fileURLWithPath: dir).standardizedFileURL.path
        }
        if raw.count > 1, raw.hasSuffix("/") {
            return String(raw.dropLast())
        }
        return raw
    }

    /// Aggregate group key for a workspace. Kept for callers (notification
    /// re-sort insertion point, etc.) that still bucket a whole workspace.
    /// Reads panel directories so a workspace doesn't bounce groups when
    /// focus shifts between two panels in different repos.
    static func groupKey(for workspace: Workspace) -> String {
        var directories: [String] = workspace.panelDirectories.values.compactMap { dir in
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if directories.isEmpty {
            let cwd = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                directories = [cwd]
            }
        }
        guard !directories.isEmpty else { return "" }

        let resolvedKeys = directories.map { dir -> String in
            let raw: String
            if let root = repoRoot(forDirectory: dir) {
                raw = root
            } else {
                raw = URL(fileURLWithPath: dir).standardizedFileURL.path
            }
            if raw.count > 1, raw.hasSuffix("/") {
                return String(raw.dropLast())
            }
            return raw
        }

        let workKeys = resolvedKeys.filter { $0 != Self.homeKey }
        let candidates = workKeys.isEmpty ? resolvedKeys : workKeys

        var counts: [String: Int] = [:]
        for key in candidates {
            counts[key, default: 0] += 1
        }

        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key ?? ""
    }

    static func displayName(forGroupKey key: String) -> String {
        guard !key.isEmpty else { return "" }
        let last = (key as NSString).lastPathComponent
        return last.isEmpty ? key : last
    }

    /// For each key in `keys`, return the shortest trailing path suffix that
    /// uniquely identifies it within the set, joined by `/`. A unique
    /// `…/cmux` stays `cmux`; two `…/cmux` keys extend to `code/cmux` vs
    /// `work/cmux`; deeper collisions keep extending until distinct.
    /// Private so the precondition "no duplicate input keys" is local to this
    /// file (enforced by `groups(from:)`'s bucket-dedup).
    private static func disambiguatedDisplayNames(forKeys keys: [String]) -> [String: String] {
        let parts: [String: [String]] = Dictionary(keys.map { key in
            let comps = (key as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
            return (key, comps)
        }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for key in keys {
            guard let myParts = parts[key], !myParts.isEmpty else {
                result[key] = key.isEmpty
                    ? String(
                        localized: "sidebar.workspaceGroup.untitled",
                        defaultValue: "Other"
                    )
                    : key
                continue
            }
            var depth = 1
            while depth < myParts.count {
                let mySuffix = Array(myParts.suffix(depth))
                let collides = keys.contains { other in
                    guard other != key, let otherParts = parts[other], otherParts.count >= depth else {
                        return false
                    }
                    return Array(otherParts.suffix(depth)) == mySuffix
                }
                if !collides { break }
                depth += 1
            }
            result[key] = myParts.suffix(depth).joined(separator: "/")
        }
        return result
    }

    /// Group panel entries by repo, then order rows *within* each group
    /// strictly by recency.
    ///
    /// CASPER (item 4): group order is first-appearance of each key in the
    /// pre-sorted input (so the group holding the most-recent session sorts
    /// first), but rows inside a group are re-sorted by per-entry activity so a
    /// workspace's split-panels are NOT forced adjacent — every session row
    /// sits at its own reverse-chronological position. The bucket's original
    /// input index is the stable tiebreak, keeping ties from jittering on every
    /// status update. Delete the within-group sort if upstream adds first-class
    /// per-session ordering.
    static func groups(from entries: [CasperSidebarPanelEntry]) -> [CasperWorkspaceGroup] {
        var order: [String] = []
        var buckets: [String: [(index: Int, entry: CasperSidebarPanelEntry)]] = [:]
        for (index, entry) in entries.enumerated() {
            let key = entry.groupKey
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = [(index, entry)]
            } else {
                buckets[key]?.append((index, entry))
            }
        }
        let names = disambiguatedDisplayNames(forKeys: order)
        return order.map { key in
            let sorted = (buckets[key] ?? []).sorted { lhs, rhs in
                if CasperAgentActivity.compareEntryActivityDesc(lhs: lhs.entry, rhs: rhs.entry) {
                    return true
                }
                if CasperAgentActivity.compareEntryActivityDesc(lhs: rhs.entry, rhs: lhs.entry) {
                    return false
                }
                return lhs.index < rhs.index
            }
            return CasperWorkspaceGroup(
                key: key,
                displayName: names[key, default: ""],
                entries: sorted.map(\.entry)
            )
        }
    }

    /// First index in `workspaces` that is unpinned and shares `bumped`'s group.
    /// Used as the insertion point so notification-driven bumps land at the top
    /// of the workspace's repo group (below any pinned siblings) rather than the
    /// top of the whole list.
    static func firstUnpinnedIndex(in workspaces: [Workspace], matching bumped: Workspace) -> Int? {
        let key = groupKey(for: bumped)
        return workspaces.firstIndex { workspace in
            !workspace.isPinned && groupKey(for: workspace) == key
        }
    }

    private static func repoRoot(forDirectory directory: String) -> String? {
        guard !directory.isEmpty else { return nil }
        if let cached = repoRootCache[directory] {
            return cached
        }
        let resolved = findRepoRoot(from: directory)
        repoRootCache[directory] = resolved
        return resolved
    }

    private static func findRepoRoot(from directory: String) -> String? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        // Cap the walk so a pathological path (e.g. symlink loop reduced via
        // standardization can't happen, but defense in depth) can't spin.
        for _ in 0..<64 {
            let gitPath = url.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}

// MARK: - Entry builder

@MainActor
enum CasperSidebarPanelEntryBuilder {
    /// Builds the sidebar's panel-entry list from the current `[Workspace]`.
    /// Each workspace emits one entry per panel; panels within a workspace are
    /// ordered by UUID (cheap and stable). Activity is per-panel when PID
    /// attribution is available (multi-panel workspaces), falling back to
    /// workspace-level for single-panel workspaces.
    static func entries(
        from workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activityByWorkspaceId: [UUID: CasperWorkspaceActivity],
        notificationStore: TerminalNotificationStore
    ) -> [CasperSidebarPanelEntry] {
        var out: [CasperSidebarPanelEntry] = []
        out.reserveCapacity(workspaces.reduce(0) { $0 + $1.panels.count })
        for workspace in workspaces {
            let isWorkspaceSelected = workspace.id == selectedWorkspaceId
            let focusedPanelId = workspace.focusedPanelId
            // Visual order from bonsplit (left-to-right pane walk, tabs in
            // tab-strip order within each pane). Falls back to UUID sort for
            // panels not yet tracked by bonsplit — see
            // `Workspace.sidebarOrderedPanelIds()`. Non-terminal panels
            // (browser, markdown, file preview) are filtered out: the sidebar
            // is a terminal session list, so the "· N" suffix counts only
            // terminal panels and stays sequential.
            let orderedPanelIds = workspace.sidebarOrderedPanelIds().filter { panelId in
                workspace.panels[panelId]?.panelType == .terminal
            }
            let panelCount = orderedPanelIds.count
            let isMultiPanel = panelCount > 1
            for (index, panelId) in orderedPanelIds.enumerated() {
                let rawTitle: String = {
                    if let custom = workspace.panelCustomTitles[panelId]?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                        return custom
                    }
                    if let title = workspace.panelTitles[panelId]?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                        return title
                    }
                    // Fallback to the workspace title. Single-panel workspaces
                    // keep today's appearance; multi-panel workspaces suffix
                    // the bonsplit index so panels with no per-panel OSC title
                    // render as distinguishable rows ("Foo · 1", "Foo · 2", …)
                    // instead of N identical strings — also stops a search
                    // query that matches `workspace.title` from returning N
                    // copies of the same row.
                    if panelCount > 1 {
                        return "\(workspace.title) · \(index + 1)"
                    }
                    return workspace.title
                }()
                let display = CasperWorkspaceTitle.displayTitle(rawTitle)
                let groupKey = CasperWorkspaceGroupResolver.groupKey(
                    forPanel: panelId,
                    in: workspace
                )
                let activity: CasperWorkspaceActivity = isMultiPanel
                    ? CasperAgentActivity.panelActivity(
                        for: workspace,
                        panelId: panelId,
                        notificationStore: notificationStore,
                        terminalPanelCount: panelCount
                    )
                    : activityByWorkspaceId[workspace.id]
                        ?? CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
                out.append(
                    CasperSidebarPanelEntry(
                        key: CasperSidebarPanelKey(
                            workspaceId: workspace.id,
                            panelId: panelId
                        ),
                        displayTitle: display,
                        rawTitle: rawTitle,
                        groupKey: groupKey,
                        isWorkspaceSelected: isWorkspaceSelected,
                        isPanelFocused: focusedPanelId == panelId,
                        isPinned: workspace.isPinned,
                        activity: activity,
                        withinWorkspaceOrder: index
                    )
                )
            }
        }
        return out
    }

    /// Workspace-mode entries — one row per workspace, anchored to the
    /// workspace's currently focused panel id (or first panel as fallback).
    /// Used by the non-compact sidebar path so the same group/sort machinery
    /// drives both modes; the only difference is the per-panel expansion.
    static func workspaceRowEntries(
        from workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activityByWorkspaceId: [UUID: CasperWorkspaceActivity]
    ) -> [CasperSidebarPanelEntry] {
        workspaces.enumerated().map { offset, workspace in
            let panelId = workspace.focusedPanelId
                ?? workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
                ?? workspace.id
            let raw = workspace.title
            let display = CasperWorkspaceTitle.displayTitle(raw)
            let groupKey = CasperWorkspaceGroupResolver.groupKey(for: workspace)
            let activity = activityByWorkspaceId[workspace.id]
                ?? CasperWorkspaceActivity(state: .none, lastActivityAt: nil)
            return CasperSidebarPanelEntry(
                key: CasperSidebarPanelKey(workspaceId: workspace.id, panelId: panelId),
                displayTitle: display,
                rawTitle: raw,
                groupKey: groupKey,
                isWorkspaceSelected: workspace.id == selectedWorkspaceId,
                isPanelFocused: true,
                isPinned: workspace.isPinned,
                activity: activity,
                withinWorkspaceOrder: offset
            )
        }
    }

    /// Substring match against the panel's display title. Empty query = all
    /// entries.
    static func filter(_ entries: [CasperSidebarPanelEntry], query: String) -> [CasperSidebarPanelEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let needle = trimmed.lowercased()
        return entries.filter { $0.displayTitle.lowercased().contains(needle) }
    }

}

// MARK: - Header / section views

struct CasperWorkspaceGroupHeader: View, Equatable {
    // CASPER: Equatable + .equatable() at the call site so the header doesn't
    // re-evaluate body when the sidebar metadata store publishes an unrelated
    // change. Closures are excluded from == — they reallocate every parent
    // eval but don't affect rendering. Delete if upstream introduces
    // Observation-tracked sidebar rows that skip closure-driven invalidation.
    nonisolated static func == (lhs: CasperWorkspaceGroupHeader, rhs: CasperWorkspaceGroupHeader) -> Bool {
        lhs.displayName == rhs.displayName &&
        lhs.isCollapsed == rhs.isCollapsed &&
        lhs.showsAddWorkspaceButton == rhs.showsAddWorkspaceButton &&
        lhs.shortcutDigit == rhs.shortcutDigit &&
        lhs.shortcutModifierSymbol == rhs.shortcutModifierSymbol &&
        lhs.showsShortcutHint == rhs.showsShortcutHint &&
        lhs.shortcutHintXOffset == rhs.shortcutHintXOffset &&
        lhs.shortcutHintYOffset == rhs.shortcutHintYOffset
    }

    let displayName: String
    let isCollapsed: Bool
    /// Drives the trailing `+` button's opacity. The parent
    /// `CasperWorkspaceGroupSection` flips this to `true` whenever the cursor
    /// is over the header or any workspace row inside the group, so the
    /// affordance also reveals while the user is on their way to or from a row.
    let showsAddWorkspaceButton: Bool
    /// `⌘N` digit for this group's display position (1 = top group). `nil`
    /// suppresses the badge — groups outside the 1–9 mapping.
    let shortcutDigit: Int?
    /// Prefix glyph(s) for the modifier — e.g. `⌘`. Sourced from the
    /// `selectWorkspaceByNumber` binding so a custom modifier renders correctly.
    let shortcutModifierSymbol: String
    /// True when the modifier is held (or the always-show debug toggle is on)
    /// — gates the shortcut pill.
    let showsShortcutHint: Bool
    /// Debug-menu nudges for the shortcut pill (Debug > Shortcut Hints).
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let onToggle: () -> Void
    let onAddWorkspace: () -> Void
    /// Closes every session in this group as one batched action (restorable in
    /// a single ⌘⇧T). Built in ContentView where `TabManager` is in scope.
    let onCloseAll: () -> Void
    /// Fired by the trailing `+` icon's own hover tracker. The parent ORs this
    /// with the section-wide hover so moving the cursor directly over the icon
    /// (which can race the parent VStack's `.onHover(false)` when SwiftUI
    /// reroutes hover to a nested interactive child) doesn't make the icon
    /// flicker away under the pointer.
    let onAddButtonHoverChange: (Bool) -> Void

    private var shortcutLabel: String? {
        guard let shortcutDigit else { return nil }
        return "\(shortcutModifierSymbol)\(shortcutDigit)"
    }

    private var showsBadge: Bool {
        showsShortcutHint && shortcutLabel != nil
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.65))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isCollapsed)
                        .frame(width: 10, alignment: .center)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.55))
                    Text(displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(displayName)
            .accessibilityValue(
                isCollapsed
                    ? String(localized: "workspace.group.collapsed", defaultValue: "Collapsed")
                    : String(localized: "workspace.group.expanded", defaultValue: "Expanded")
            )
            .accessibilityHint(String(
                localized: "workspace.group.toggleHint",
                defaultValue: "Double-tap to toggle workspace group."
            ))

            // Image + `.onTapGesture` (not `Button`) — matches the close-icon
            // pattern in `SessionIndexView` and avoids the SwiftUI bug where a
            // nested `Button`'s internal mouse tracking causes the parent
            // VStack's `.onHover(false)` to fire while the cursor is over the
            // child, which made the icon disappear right under the pointer.
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.85))
                // Trailing-align so the visible glyph's right edge (not the
                // 16pt frame's) lines up with the workspace row's time column.
                .frame(width: 16, height: 16, alignment: .trailing)
                .contentShape(Rectangle())
                // Hide the `+` while the shortcut badge is showing so they
                // don't overlap in the same trailing column.
                .opacity(showsAddWorkspaceButton && !showsBadge ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: showsAddWorkspaceButton)
                .onHover { onAddButtonHoverChange($0) }
                .onTapGesture { onAddWorkspace() }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(String(
                    format: String(
                        localized: "workspace.group.newWorkspace.label",
                        defaultValue: "New workspace in %@"
                    ),
                    displayName
                ))
                .accessibilityHint(String(
                    localized: "workspace.group.newWorkspace.hint",
                    defaultValue: "Creates a new workspace anchored to this group's directory."
                ))
        }
        .padding(.leading, 10)
        // Trailing 16 = workspace row outer 6 + inner trailing 10, so the
        // header `+` right edge lines up with the row's activity-time column.
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ⌘N badge for this group, shown while the modifier is held. Trailing
        // overlay so it shares the `+` column without widening the header.
        .overlay(alignment: .trailing) {
            if showsBadge, let shortcutLabel {
                ShortcutHintPill(text: shortcutLabel, fontSize: 10, emphasis: 0.9)
                    .offset(
                        x: ShortcutHintDebugSettings.clamped(shortcutHintXOffset),
                        y: ShortcutHintDebugSettings.clamped(shortcutHintYOffset)
                    )
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
                    .shortcutHintTransition()
            }
        }
        .shortcutHintVisibilityAnimation(value: showsBadge)
        // CASPER: right-click (two-finger) context menu for the whole group.
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onAddWorkspace()
        } label: {
            Label(
                String(localized: "sidebar.group.menu.newSession", defaultValue: "New Session"),
                systemImage: "plus"
            )
        }
        Button {
            onToggle()
        } label: {
            Label(
                isCollapsed
                    ? String(localized: "sidebar.group.menu.expand", defaultValue: "Expand Group")
                    : String(localized: "sidebar.group.menu.collapse", defaultValue: "Collapse Group"),
                systemImage: isCollapsed ? "chevron.down" : "chevron.right"
            )
        }
        Divider()
        Button(role: .destructive) {
            onCloseAll()
        } label: {
            Label(
                String(localized: "sidebar.group.menu.closeAll", defaultValue: "Close All Sessions"),
                systemImage: "xmark"
            )
        }
    }
}

/// Wraps a workspace group's header and rows so a single hover detector covers
/// both. The `+` on the header reveals whenever the cursor is anywhere inside
/// the group's visual bounds — header OR any row.
struct CasperWorkspaceGroupSection<Content: View>: View {
    let displayName: String
    let isCollapsed: Bool
    /// True when this group holds the active session — the whole group gets a
    /// light-blue tint while the active session row keeps the stronger
    /// selection highlight on top.
    let isSelected: Bool
    let withinGroupSpacing: CGFloat
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String
    let showsShortcutHint: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let onToggle: () -> Void
    let onAddWorkspace: () -> Void
    let onCloseAll: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHoveringSection: Bool = false
    @State private var isHoveringAddButton: Bool = false

    private var isHovering: Bool { isHoveringSection || isHoveringAddButton }

    var body: some View {
        VStack(spacing: withinGroupSpacing) {
            if !displayName.isEmpty {
                CasperWorkspaceGroupHeader(
                    displayName: displayName,
                    isCollapsed: isCollapsed,
                    showsAddWorkspaceButton: isHovering,
                    shortcutDigit: shortcutDigit,
                    shortcutModifierSymbol: shortcutModifierSymbol,
                    showsShortcutHint: showsShortcutHint,
                    shortcutHintXOffset: shortcutHintXOffset,
                    shortcutHintYOffset: shortcutHintYOffset,
                    onToggle: onToggle,
                    onAddWorkspace: onAddWorkspace,
                    onCloseAll: onCloseAll,
                    onAddButtonHoverChange: { newValue in
                        guard isHoveringAddButton != newValue else { return }
                        isHoveringAddButton = newValue
                    }
                )
                // CASPER: see CasperWorkspaceGroupHeader ==(_:_:).
                .equatable()
            }
            if !isCollapsed {
                content()
            }
        }
        // CASPER: light-blue "selected group" tint behind the header + rows.
        // Inset 6 on each side so it lines up with the row selection pills.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.12) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .overlay {
            CasperHoverTracker { hovering in
                let next = (isCollapsed && !hovering) ? false : hovering
                guard isHoveringSection != next else { return }
                isHoveringSection = next
            }
        }
    }
}

// MARK: - Row context-menu actions

/// CASPER: closure bundle for a session row's right-click context menu. Built
/// per-entry in ContentView (where `TabManager` + rename/command-palette flows
/// are in scope) and handed to the row as immutable value+closures, preserving
/// the snapshot-boundary rule (rows never reach into a store). Closures are
/// excluded from `CasperSidebarPanelRow ==`. Delete with the context menu if
/// upstream adds first-class per-session row actions.
struct CasperSidebarRowActions {
    /// Gates the cwd-dependent items (reveal / open / copy / duplicate).
    let hasWorkingDirectory: Bool
    /// Gates the "Fork Session" item — true only when a forkable (claude/codex)
    /// agent is live on this panel. See `CasperForkSession.forkableKind`.
    let canForkAgent: Bool
    let onRename: () -> Void
    let onRevealInFinder: () -> Void
    let onOpenWorkingDirectory: () -> Void
    let onCopyPath: () -> Void
    let onTogglePin: () -> Void
    let onDuplicate: () -> Void
    let onForkSession: () -> Void
}

// MARK: - Panel row view

/// Compact one-line row for a single panel inside a workspace. Rendered by
/// the Casper compact sidebar in place of the workspace-level `TabItemView`
/// so multi-panel workspaces surface every panel as its own selectable row.
///
/// Snapshot-boundary contract: receives only the `entry` value snapshot plus
/// closure callbacks. Never reaches into a `Workspace` / `TabManager` / store
/// from inside its body — see `Sources/SessionIndexView.swift` for the
/// reference pattern and GH #2586 for the spin-loop incident.
///
/// Click selects the workspace and focuses this panel; close calls back into
/// the parent to invoke `Workspace.closePanel(panelId)`.
struct CasperSidebarPanelRow: View, Equatable {
    // CASPER: Equatable + .equatable() at the ForEach call site so rows skip
    // body re-evaluation when the sidebar metadata store publishes a change
    // that doesn't affect this specific row. Without this, every
    // panelGitBranches / panelPullRequests / panelTitles publish re-evaluates
    // every visible row, accumulating display-list churn that backs the
    // render server up into multi-hundred-ms CA::Transaction::commit waits
    // (foreground-only freeze). Closures, @State, and @Environment are
    // excluded from == — they don't affect this row's visible inputs.
    // Delete if upstream introduces Observation-tracked sidebar rows that
    // skip closure-driven invalidation.
    nonisolated static func == (lhs: CasperSidebarPanelRow, rhs: CasperSidebarPanelRow) -> Bool {
        lhs.entry == rhs.entry
    }

    let entry: CasperSidebarPanelEntry
    let onSelect: () -> Void
    let onClose: () -> Void
    /// Right-click context-menu action bundle. Closures only — excluded from ==.
    let actions: CasperSidebarRowActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringRow: Bool = false

    /// Three-level selection highlight for the row.
    /// `.selected` = the focused panel of the selected workspace (solid blue).
    /// `.sibling` = another panel in that same workspace (lighter blue, so the
    /// panels of a multi-panel workspace read as one group). `.none` = unrelated.
    private enum Highlight: Equatable {
        case selected
        case sibling
        case none
    }

    private var highlight: Highlight {
        guard entry.isWorkspaceSelected else { return .none }
        return entry.isPanelFocused ? .selected : .sibling
    }

    private var selectedBackground: Color {
        Color(nsColor: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme))
    }

    /// Lighter wash of the selection blue for sibling panels in the same
    /// workspace. Same hue as the active row so they visibly belong together.
    private var siblingBackground: Color {
        selectedBackground.opacity(0.22)
    }

    var body: some View {
        let activity = entry.activity
        let highlight = self.highlight
        let selected = highlight == .selected
        let rowBackground: Color = {
            switch highlight {
            case .selected: return selectedBackground
            case .sibling: return siblingBackground
            case .none: return Color.clear
            }
        }()
        // Outer Button (vs. `.onTapGesture`) so the inner close Button cleanly
        // consumes its own click — SwiftUI on macOS nests plain Buttons with
        // inner-wins hit routing.
        Button(action: onSelect) {
            HStack(spacing: 5) {
                // 10pt width aligns the X with the workspace-group chevron column.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(
                            selected
                                ? Color.white.opacity(0.85)
                                : Color.secondary.opacity(0.7)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 10, height: 16, alignment: .center)
                .opacity(isHoveringRow ? 1 : 0)
                .allowsHitTesting(isHoveringRow)
                .accessibilityLabel(String(
                    localized: "sidebar.panel.close.label",
                    defaultValue: "Close panel"
                ))

                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(
                            selected
                                ? Color.white.opacity(0.85)
                                : Color.secondary.opacity(0.8)
                        )
                }

                Text(entry.displayTitle)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                CasperWorkspaceActivityIndicator(
                    activityProvider: { activity },
                    timeFont: .system(size: 10, weight: .regular),
                    doneColor: Color.secondary.opacity(0.65),
                    selectedColor: selected ? Color.white : nil
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            CasperHoverTracker { hovering in
                guard isHoveringRow != hovering else { return }
                isHoveringRow = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.displayTitle)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        // CASPER: right-click (two-finger) context menu for the session row.
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            actions.onRename()
        } label: {
            Label(
                String(localized: "sidebar.session.menu.rename", defaultValue: "Rename…"),
                systemImage: "pencil"
            )
        }
        Button {
            actions.onTogglePin()
        } label: {
            Label(
                entry.isPinned
                    ? String(localized: "sidebar.session.menu.unpin", defaultValue: "Unpin Workspace")
                    : String(localized: "sidebar.session.menu.pin", defaultValue: "Pin Workspace"),
                systemImage: entry.isPinned ? "pin.slash" : "pin"
            )
        }
        if actions.canForkAgent {
            Divider()
            // CASPER: branch the live claude/codex agent into a new workspace.
            Button {
                actions.onForkSession()
            } label: {
                Label(
                    String(localized: "sidebar.session.menu.fork", defaultValue: "Fork Session"),
                    systemImage: "arrow.triangle.branch"
                )
            }
        }
        if actions.hasWorkingDirectory {
            Divider()
            Button {
                actions.onDuplicate()
            } label: {
                Label(
                    String(localized: "sidebar.session.menu.duplicate", defaultValue: "Duplicate Session"),
                    systemImage: "plus.square.on.square"
                )
            }
            Button {
                actions.onOpenWorkingDirectory()
            } label: {
                Label(
                    String(localized: "sidebar.session.menu.openWorkingDirectory", defaultValue: "Open Working Directory"),
                    systemImage: "folder"
                )
            }
            Button {
                actions.onRevealInFinder()
            } label: {
                Label(
                    String(localized: "sidebar.session.menu.revealInFinder", defaultValue: "Reveal in Finder"),
                    systemImage: "magnifyingglass"
                )
            }
            Button {
                actions.onCopyPath()
            } label: {
                Label(
                    String(localized: "sidebar.session.menu.copyPath", defaultValue: "Copy Path"),
                    systemImage: "doc.on.clipboard"
                )
            }
        }
        Divider()
        Button(role: .destructive) {
            onClose()
        } label: {
            Label(
                String(localized: "sidebar.session.menu.close", defaultValue: "Close Session"),
                systemImage: "xmark"
            )
        }
    }
}

// MARK: - Hover tracking

/// AppKit-backed hover detector for the compact sidebar's row + group section.
/// SwiftUI's `.onHover` modifier transiently misses hover state when the row
/// subtree re-evaluates under main-thread load (sort flips, activity bumps,
/// session-map refreshes): the modifier's NSTrackingArea is torn down and
/// re-installed without replaying `mouseEntered` against the cursor's current
/// position, so `isHoveringRow` / `isHoveringSection` stays stuck at `false`
/// even while the cursor is over the row — hiding the X / `+` affordances.
///
/// This tracker reinstalls its tracking area in `updateTrackingAreas` like a
/// normal NSView, AND polls `window.mouseLocationOutsideOfEventStream` from
/// `updateTrackingAreas` / `viewDidMoveToWindow` so the post-layout hover state
/// is always reconciled against the actual pointer position. Mirrors the
/// `SidebarWorkspaceRowHoverTracker` pattern used by the non-compact
/// `TabItemView` — kept separate so the compact path doesn't pull in
/// `SidebarWorkspaceRowInteractionState`'s context-menu plumbing.
struct CasperHoverTracker: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> CasperHoverTrackingView {
        let view = CasperHoverTrackingView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: CasperHoverTrackingView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class CasperHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var lastReportedHover: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
        reconcileCurrentPointerLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileCurrentPointerLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        reconcileCurrentPointerLocation()
    }

    override func mouseExited(with event: NSEvent) {
        report(false)
    }

    private func reconcileCurrentPointerLocation() {
        guard let window else {
            report(false)
            return
        }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = convert(pointInWindow, from: nil)
        report(bounds.contains(pointInView))
    }

    private func report(_ hovering: Bool) {
        guard lastReportedHover != hovering else { return }
        lastReportedHover = hovering
        onHoverChanged?(hovering)
    }
}

/// Per-group collapse state, persisted to UserDefaults.
/// Lives at the sidebar level so it can be observed without violating the
/// snapshot-boundary rule (rows receive only value-typed snapshots from the
/// parent and never reach into this store themselves).
@MainActor
final class CasperWorkspaceGroupCollapseStore: ObservableObject {
    static let shared = CasperWorkspaceGroupCollapseStore()

    private static let defaultsKey = "casperWorkspaceGroupCollapsedKeys"

    @Published private(set) var collapsedKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        let raw = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        self.collapsedKeys = Set(raw)
    }

    func isCollapsed(_ key: String) -> Bool {
        collapsedKeys.contains(key)
    }

    func toggle(_ key: String, defaults: UserDefaults = .standard) {
        if collapsedKeys.contains(key) {
            collapsedKeys.remove(key)
        } else {
            collapsedKeys.insert(key)
        }
        defaults.set(Array(collapsedKeys).sorted(), forKey: Self.defaultsKey)
    }

    /// Expand a collapsed group (no-op if already expanded). Used by ⌘1…9 group
    /// selection so targeting a collapsed group reveals its sessions.
    func expand(_ key: String, defaults: UserDefaults = .standard) {
        guard collapsedKeys.contains(key) else { return }
        collapsedKeys.remove(key)
        defaults.set(Array(collapsedKeys).sorted(), forKey: Self.defaultsKey)
    }
}
