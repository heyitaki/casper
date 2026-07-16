// CASPER: keyboard navigation across the compact sidebar's session rows.
//
// ⌘↑/↓ steps one session row at a time through the displayed order; ⌘⇧↑/↓
// jumps to the first (top-most) session of the previous/next workspace. The
// navigator reconstructs the same row order the sidebar renders by calling the
// same shared building blocks (`CasperAgentActivity.compareActivityDesc`,
// `CasperSidebarPanelEntryBuilder.entries`, `CasperWorkspaceGroupResolver.
// groups`) in the same sequence, so a keypress always lands on a row that is
// actually on screen.
//
// Delete if upstream adds first-class keyboard navigation of sidebar rows.

import AppKit
import Foundation

@MainActor
enum CasperSidebarNavigator {
    enum Direction {
        case next
        case previous
    }

    enum Granularity {
        /// One session row at a time (⌘↑/↓).
        case session
        /// First session of the previous/next workspace (⌘⇧↑/↓).
        case workspace
    }

    /// Convenience entry point for the AppDelegate shortcut dispatch. Resolves
    /// the focused window's `TabManager` + `TerminalNotificationStore` and moves
    /// focus. No-ops (returning `false`) when there's nothing to navigate so the
    /// caller can decide whether to keep consuming the event.
    @discardableResult
    static func handleShortcut(
        direction: Direction,
        granularity: Granularity
    ) -> Bool {
        guard let tabManager = AppDelegate.shared?.tabManager,
              let notificationStore = AppDelegate.shared?.notificationStore else {
            return false
        }
        return move(
            direction: direction,
            granularity: granularity,
            tabManager: tabManager,
            notificationStore: notificationStore
        )
    }

    /// Displayed group order. Mirrors `workspaceRows(renderContext:)` in
    /// ContentView up to (but not including) the collapse filter: same activity
    /// sort, entry build, search filter, and grouping. Collapsed groups are
    /// KEPT here because group-level selection (⌘1…9) must be able to target a
    /// collapsed group and expand it.
    static func orderedGroups(
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) -> [CasperWorkspaceGroup] {
        let tabs = tabManager.tabs
        guard !tabs.isEmpty else { return [] }
        // KEEP IN SYNC with `VerticalTabsSidebar.workspaceRows(renderContext:)` in
        // ContentView — same activity sort, entry build, search filter, and
        // grouping. If the view's ordering changes, mirror it here or ⌘↑/↓ and
        // ⌘1…9 will land on rows/groups that aren't where the user sees them.
        let activityByID: [UUID: CasperWorkspaceActivity] = Dictionary(
            uniqueKeysWithValues: tabs.map { tab in
                (tab.id, CasperAgentActivity.activity(for: tab, notificationStore: notificationStore))
            }
        )
        let sortedTabs = tabs.enumerated().sorted { lhs, rhs in
            if CasperAgentActivity.compareActivityDesc(
                lhs: lhs.element,
                rhs: rhs.element,
                activityByID: activityByID
            ) {
                return true
            }
            if CasperAgentActivity.compareActivityDesc(
                lhs: rhs.element,
                rhs: lhs.element,
                activityByID: activityByID
            ) {
                return false
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let entries = CasperSidebarPanelEntryBuilder.entries(
            from: sortedTabs,
            selectedWorkspaceId: tabManager.selectedTabId,
            activityByWorkspaceId: activityByID,
            notificationStore: notificationStore
        )
        let filtered = CasperSidebarPanelEntryBuilder.filter(
            entries,
            query: CasperSidebarSearchQueryStore.shared.query
        )
        return CasperWorkspaceGroupResolver.groups(from: filtered)
    }

    /// Flattened, displayed row order. The two things that change what's
    /// actually on screen — the active search filter (the query persists when
    /// the user clicks away from the field without pressing Escape) and
    /// collapsed folder groups — are both applied so ⌘↑/↓ can never land on a
    /// row that isn't rendered.
    static func orderedEntries(
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) -> [CasperSidebarPanelEntry] {
        // Drop rows inside collapsed groups, matching the view (which collapses
        // only named groups — see `CasperSidebarRenderPlan.build`).
        let collapsedKeys = CasperWorkspaceGroupCollapseStore.shared.collapsedKeys
        return orderedGroups(tabManager: tabManager, notificationStore: notificationStore)
            .filter { $0.displayName.isEmpty || !collapsedKeys.contains($0.key) }
            .flatMap(\.entries)
    }

    /// ⌘1…9 entry point: select the Nth displayed workspace group. Group order
    /// is most-recent-first (⌘1 = top group). Selecting a group focuses its
    /// top-most (most-recent) session — which makes that group the "active"
    /// group (the sidebar tints it) — and expands it if collapsed. Pressing the
    /// same digit again, while its group is already active, toggles the group
    /// collapsed/open and keeps the current session selected.
    @discardableResult
    static func selectGroup(digit: Int) -> Bool {
        guard let tabManager = AppDelegate.shared?.tabManager,
              let notificationStore = AppDelegate.shared?.notificationStore else {
            return false
        }
        let groups = orderedGroups(tabManager: tabManager, notificationStore: notificationStore)
        guard !groups.isEmpty else { return false }
        // Reuse the workspace-number index mapping (1–8 fixed, 9 = last) for
        // groups so the digit semantics match the badge the header shows.
        guard let index = WorkspaceShortcutMapper.workspaceIndex(
            forDigit: digit,
            workspaceCount: groups.count
        ) else { return false }
        let target = groups[index]

        if target.key == activeGroupKey(in: groups, tabManager: tabManager) {
            // Already the active group → toggle collapse, keep selection. The
            // unnamed "Other" bucket has no header and can't collapse, so no-op.
            if !target.displayName.isEmpty {
                CasperWorkspaceGroupCollapseStore.shared.toggle(target.key)
            }
            tabManager.casperGroupSelectionActive = true
            return true
        }

        // Not yet active → reveal (if collapsed) and focus the group's top
        // session so the whole group reads as selected.
        if !target.displayName.isEmpty {
            CasperWorkspaceGroupCollapseStore.shared.expand(target.key)
        }
        guard let top = target.entries.first else { return false }
        tabManager.focusTab(top.key.workspaceId, surfaceId: top.key.panelId)
        // Set AFTER focusTab, whose selectedTabId change clears the flag via
        // didSet, so group-selected mode wins.
        tabManager.casperGroupSelectionActive = true
        return true
    }

    /// ⌘W in group-selected mode: close every session in the active group as
    /// one batched, ⌘⇧T-reopenable action. Returns false (no-op) when no group
    /// is active. Delete with group selection.
    @discardableResult
    static func closeActiveGroup() -> Bool {
        guard let tabManager = AppDelegate.shared?.tabManager,
              let notificationStore = AppDelegate.shared?.notificationStore else {
            return false
        }
        let groups = orderedGroups(tabManager: tabManager, notificationStore: notificationStore)
        guard let activeKey = activeGroupKey(in: groups, tabManager: tabManager),
              let group = groups.first(where: { $0.key == activeKey }) else {
            return false
        }
        var seen = Set<UUID>()
        let workspaceIds = group.entries.compactMap { entry in
            seen.insert(entry.key.workspaceId).inserted ? entry.key.workspaceId : nil
        }
        guard !workspaceIds.isEmpty else { return false }
        // Clear before dispatching: the group is being torn down, so there's no
        // group to stay "selected" in.
        tabManager.casperGroupSelectionActive = false
        tabManager.casperCloseWorkspaceGroup(workspaceIds: workspaceIds)
        return true
    }

    /// Key of the group that currently holds the active session (selected
    /// workspace + focused panel). `nil` when nothing matches.
    static func activeGroupKey(
        in groups: [CasperWorkspaceGroup],
        tabManager: TabManager
    ) -> String? {
        guard let selectedTabId = tabManager.selectedTabId else { return nil }
        let focusedPanelId = tabManager.focusedPanelId(for: selectedTabId)
        // Prefer the exact focused (workspace, panel) row; fall back to any row
        // of the selected workspace (panels of one workspace can span groups).
        if let focusedPanelId,
           let group = groups.first(where: { group in
               group.entries.contains { $0.key.workspaceId == selectedTabId && $0.key.panelId == focusedPanelId }
           }) {
            return group.key
        }
        return groups.first { group in
            group.entries.contains { $0.key.workspaceId == selectedTabId }
        }?.key
    }

    @discardableResult
    static func move(
        direction: Direction,
        granularity: Granularity,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) -> Bool {
        let entries = orderedEntries(tabManager: tabManager, notificationStore: notificationStore)
        guard !entries.isEmpty else { return false }

        let anchorIndex = currentAnchorIndex(in: entries, tabManager: tabManager)
        let targetIndex: Int
        switch granularity {
        case .session:
            targetIndex = sessionStep(from: anchorIndex, direction: direction, count: entries.count)
        case .workspace:
            guard let next = workspaceStep(from: anchorIndex, direction: direction, entries: entries) else {
                return false
            }
            targetIndex = next
        }
        guard targetIndex >= 0, targetIndex < entries.count else { return false }
        let target = entries[targetIndex]
        tabManager.focusTab(target.key.workspaceId, surfaceId: target.key.panelId)
        return true
    }

    /// Anchor = the focused panel of the selected workspace, falling back to the
    /// workspace's first row, then the top of the list.
    private static func currentAnchorIndex(
        in entries: [CasperSidebarPanelEntry],
        tabManager: TabManager
    ) -> Int {
        guard let selectedTabId = tabManager.selectedTabId else { return 0 }
        if let focusedPanelId = tabManager.focusedPanelId(for: selectedTabId),
           let idx = entries.firstIndex(where: {
               $0.key.workspaceId == selectedTabId && $0.key.panelId == focusedPanelId
           }) {
            return idx
        }
        if let idx = entries.firstIndex(where: { $0.key.workspaceId == selectedTabId }) {
            return idx
        }
        return 0
    }

    private static func sessionStep(from index: Int, direction: Direction, count: Int) -> Int {
        switch direction {
        case .next: return (index + 1) % count
        case .previous: return (index - 1 + count) % count
        }
    }

    /// Visual workspace order = first-appearance of each workspace id in the
    /// flattened row list (after de-clumping, a workspace's rows can be
    /// non-contiguous, so first-appearance is the stable "top-most session"
    /// anchor). Stepping wraps and lands on the target workspace's top-most row.
    private static func workspaceStep(
        from index: Int,
        direction: Direction,
        entries: [CasperSidebarPanelEntry]
    ) -> Int? {
        var workspaceOrder: [UUID] = []
        var firstIndexByWorkspace: [UUID: Int] = [:]
        for (i, entry) in entries.enumerated() where firstIndexByWorkspace[entry.key.workspaceId] == nil {
            firstIndexByWorkspace[entry.key.workspaceId] = i
            workspaceOrder.append(entry.key.workspaceId)
        }
        guard workspaceOrder.count > 1 else { return nil }
        let currentWorkspace = entries[index].key.workspaceId
        guard let position = workspaceOrder.firstIndex(of: currentWorkspace) else { return nil }
        let nextPosition: Int
        switch direction {
        case .next: nextPosition = (position + 1) % workspaceOrder.count
        case .previous: nextPosition = (position - 1 + workspaceOrder.count) % workspaceOrder.count
        }
        return firstIndexByWorkspace[workspaceOrder[nextPosition]]
    }
}

// CASPER: holds the compact sidebar's current search query so the off-view
// keyboard navigator can apply the same filter the sidebar renders. Written by
// `VerticalTabsSidebar` whenever the query changes; read by
// `CasperSidebarNavigator.orderedEntries`. Plain holder (not observable) — the
// navigator only reads it imperatively on a keypress. Delete with the nav.
@MainActor
final class CasperSidebarSearchQueryStore {
    static let shared = CasperSidebarSearchQueryStore()
    var query: String = ""
    private init() {}
}
