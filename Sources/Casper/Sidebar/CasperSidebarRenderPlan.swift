// CASPER: flat render plan for the branded sidebar.
//
// Converts the precomputed panel-entry + group structure into a flat
// `[CasperSidebarRenderItem]` list that the sidebar's ForEach can render
// without `for`/`guard` in a @ViewBuilder body (Swift result-builder rules
// forbid imperative control flow there).
//
// The plan also computes `displayedWorkspaceIds` — the ordered list of
// workspace IDs that are visible after collapse, used to resolve shift-click
// ranges in the panel-keyed sidebar. This list is distinct from
// `tabManager.tabs` order (which is activity-sorted within the plan) and
// from `lastSidebarSelectionIndex`'s index space (which remains
// `tabManager.tabs`-indexed for the non-branded path and drag machinery).
//
// Delete if upstream adds first-class per-panel sidebar rows grouped by repo.

import Foundation

// MARK: - Plan item

/// One renderable item in the Casper branded sidebar.
@MainActor
enum CasperSidebarRenderItem {
    /// Collapsible repo-group header. `isCollapsed` is precomputed from the
    /// collapse store so the ForEach body stays a pure value render.
    /// `isFirstInPlan` is true only for the very first header in the flat
    /// items list — used by the renderer to suppress the between-group top
    /// padding on the first group (matches the old CasperWorkspaceGroupSection
    /// `.padding(.top, offset == 0 ? 0 : betweenGroupSpacing)` pattern).
    case repoGroupHeader(CasperWorkspaceGroup, isCollapsed: Bool, isFirstInPlan: Bool)
    /// A single panel row inside an expanded group.
    case panelRow(CasperSidebarPanelEntry, ownsWorkspaceAnchor: Bool)

    var id: String {
        switch self {
        case .repoGroupHeader(let group, _, _):
            // Group keys can be empty (the "Other" bucket) — prefix to keep
            // ids distinct from panel ids (which use UUID strings).
            return "repoGroup.\(group.key)"
        case .panelRow(let entry, _):
            return "panelRow.\(entry.id.uuidString)"
        }
    }
}

// MARK: - Plan builder

/// Assembles the flat `[CasperSidebarRenderItem]` for one sidebar render pass.
///
/// Inputs are pure value types (no store references); the caller (the sidebar
/// body function) is the observer boundary. Collapse state is read from the
/// store by the caller and passed in as `collapsedKeys`.
///
/// `firstEntryIdsPerWorkspace` tracks which panel-row entry owns the
/// workspace-level SwiftUI anchors (scroll-to-selected, bonsplit drop target).
/// Without this, multiple rows for the same workspace would each emit the same
/// anchor UUID and the last writer would win arbitrarily.
@MainActor
enum CasperSidebarRenderPlan {
    /// Build the flat render plan and the displayed-workspace-id order.
    ///
    /// - Parameters:
    ///   - groups: Groups from `CasperWorkspaceGroupResolver.groups(from:)`,
    ///             already in first-appearance (activity-sorted) order.
    ///   - collapsedKeys: Snapshot of `CasperWorkspaceGroupCollapseStore.collapsedKeys`.
    ///   - showSingleGroupHeader: When `false` the single-group case renders no
    ///             header (keeps the list clean when all workspaces share one repo).
    /// - Returns:
    ///   `items` — flat list ready for a ForEach.
    ///   `displayedWorkspaceIds` — workspace IDs visible after collapsing, in
    ///             the order they appear in the plan. Used for shift-click range
    ///             selection in the panel-keyed branded sidebar.
    static func build(
        groups: [CasperWorkspaceGroup],
        collapsedKeys: Set<String>,
        showSingleGroupHeader: Bool = false
    ) -> (items: [CasperSidebarRenderItem], displayedWorkspaceIds: [UUID]) {
        var items: [CasperSidebarRenderItem] = []
        var displayedWorkspaceIds: [UUID] = []
        // Track which entry id is the first per workspace for anchor ownership.
        var firstEntryIdByWorkspace: [UUID: UUID] = [:]

        let renderHeader = showSingleGroupHeader || groups.count > 1
        // Track whether any header has been emitted yet so the first group
        // header can suppress its top between-group padding.
        var firstHeaderEmitted = false

        for group in groups {
            let isCollapsed = !group.displayName.isEmpty
                && collapsedKeys.contains(group.key)

            if renderHeader && !group.displayName.isEmpty {
                let isFirst = !firstHeaderEmitted
                firstHeaderEmitted = true
                items.append(.repoGroupHeader(group, isCollapsed: isCollapsed, isFirstInPlan: isFirst))
            }

            guard !isCollapsed else { continue }

            // Track which workspace IDs we've already added to displayedWorkspaceIds
            // so multi-panel workspaces contribute exactly one entry to the order.
            var addedWorkspaceIds: Set<UUID> = []
            for entry in group.entries {
                let workspaceId = entry.key.workspaceId
                let ownsAnchor: Bool
                if firstEntryIdByWorkspace[workspaceId] == nil {
                    firstEntryIdByWorkspace[workspaceId] = entry.id
                    ownsAnchor = true
                } else {
                    ownsAnchor = false
                }
                items.append(.panelRow(entry, ownsWorkspaceAnchor: ownsAnchor))
                if addedWorkspaceIds.insert(workspaceId).inserted {
                    displayedWorkspaceIds.append(workspaceId)
                }
            }
        }

        return (items, displayedWorkspaceIds)
    }
}
