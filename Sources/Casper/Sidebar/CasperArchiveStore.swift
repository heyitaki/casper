// CASPER: sidebar session archive.
//
// An "Archive" section at the bottom of the compact sidebar holds individual
// sessions (terminal panels) the user has stashed out of the active list.
// Archiving is per-session (per-panel): "archive" is a sidebar-row presentation
// concept, not a workspace-detachment one — the panel stays in its workspace's
// bonsplit tree, only its sidebar row relocates. So a multi-panel workspace can
// have one session archived and the rest active; the workspace then shows rows
// in both the active groups and the Archive. An "Archive Workspace" action
// (offered only for multi-panel workspaces) archives all of a workspace's
// session rows at once.
//
// Selecting an archived session only *displays* it (it stays listed in the
// Archive). It returns to the active list only when the user actually submits
// work into it: a Return-key command/agent-message in its terminal, a Feed
// reply, or the explicit "Move to Active Sessions" menu item.
//
// Cross-restart durability rides the session snapshot: panel UUIDs are
// regenerated on restore, so the archived set is repopulated from
// `SessionPanelSnapshot.archived` as each panel is rebuilt (see
// `Workspace.applySessionPanelMetadata`). The section-collapsed flag is a plain
// bool, so it persists via UserDefaults.
//
// Delete if upstream adds a first-class session archive to the sidebar.

import AppKit
import Foundation
import SwiftUI

// MARK: - Store

/// Live archive state, keyed by panel (session) id. Lives at the sidebar level
/// so it can be observed without violating the snapshot-boundary rule — rows
/// receive only the value-typed `isArchived` flag baked into their entry plus
/// closure actions, and never reach into this store themselves.
@MainActor
final class CasperArchiveStore: ObservableObject {
    static let shared = CasperArchiveStore()

    private static let collapsedDefaultsKey = "casperArchiveSectionCollapsed"

    /// Panel (session) ids currently in the archive. Source of truth at runtime;
    /// persisted across restarts through the per-panel session snapshot, not here
    /// (UUIDs are regenerated on restore).
    @Published private(set) var archivedPanelIds: Set<UUID> = []

    /// Archive section expand/collapse. A plain bool with stable identity, so
    /// UserDefaults persistence is restart-safe (unlike the id set).
    @Published var isCollapsed: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isCollapsed = defaults.bool(forKey: Self.collapsedDefaultsKey)
    }

    /// Cheapest possible gate for hot paths (every Return keystroke). When the
    /// archive is empty — the overwhelmingly common case — callers skip all
    /// further work with a single bool read.
    var hasArchivedSessions: Bool {
        !archivedPanelIds.isEmpty
    }

    func isArchived(_ panelId: UUID) -> Bool {
        archivedPanelIds.contains(panelId)
    }

    func archive(_ panelId: UUID) {
        guard !archivedPanelIds.contains(panelId) else { return }
        archivedPanelIds.insert(panelId)
    }

    func unarchive(_ panelId: UUID) {
        guard archivedPanelIds.contains(panelId) else { return }
        archivedPanelIds.remove(panelId)
    }

    func toggle(_ panelId: UUID) {
        if archivedPanelIds.contains(panelId) {
            archivedPanelIds.remove(panelId)
        } else {
            archivedPanelIds.insert(panelId)
        }
    }

    /// Archive several sessions at once (the "Archive Workspace" action). Inserts
    /// only the ids not already archived and publishes a single change.
    func archivePanels(_ panelIds: [UUID]) {
        let next = archivedPanelIds.union(panelIds)
        guard next != archivedPanelIds else { return }
        archivedPanelIds = next
    }

    /// Called when the user *submits* work into a session (Return in the
    /// terminal, a Feed reply). No-op unless the session is archived, so the
    /// gate above keeps the common path free. Moves the session back to the
    /// active list.
    func noteUserSubmit(panelId: UUID) {
        guard archivedPanelIds.contains(panelId) else { return }
        archivedPanelIds.remove(panelId)
    }

    /// Drop any ids not in `livePanelIds`. Keeps the set from accumulating stale
    /// entries when a panel is closed (or restored under a new id) while
    /// archived. Publishes once.
    func pruneMissing(livePanelIds: Set<UUID>) {
        let pruned = archivedPanelIds.intersection(livePanelIds)
        guard pruned != archivedPanelIds else { return }
        archivedPanelIds = pruned
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        defaults.set(collapsed, forKey: Self.collapsedDefaultsKey)
    }

    func toggleCollapsed() {
        setCollapsed(!isCollapsed)
    }
}

// MARK: - Submit detection

/// Decides whether a key event is a "submit" gesture that should pull an
/// archived session back into the active list. A plain Return (or keypad Enter)
/// submits a shell command or sends an agent message; Shift/Option+Return are
/// newline gestures in agent composers and must NOT count.
enum CasperArchiveSubmitDetector {
    private static let returnKeyCode: UInt16 = 36       // kVK_Return
    private static let keypadEnterKeyCode: UInt16 = 76  // kVK_ANSI_KeypadEnter

    static func isSubmitReturn(_ event: NSEvent) -> Bool {
        guard event.keyCode == returnKeyCode || event.keyCode == keypadEnterKeyCode else {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift+Return / Option+Return insert a newline in TUIs — not a submit.
        if flags.contains(.shift) || flags.contains(.option) {
            return false
        }
        return true
    }
}

// MARK: - Archive section view

/// Bottom-of-sidebar "Archive" section: a collapsible header (archivebox icon,
/// title, count) over the supplied archived rows. Mirrors
/// `CasperWorkspaceGroupSection`'s header styling so archived rows read as the
/// same kind of list, with a distinct icon to signal the stashed state. Render
/// only when there is at least one archived session.
struct CasperArchiveSection<Content: View>: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 1) {
            header
            if !isCollapsed {
                content()
            }
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.65))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isCollapsed)
                    .frame(width: 10, alignment: .center)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.55))
                // Title + count share one baseline-aligned row so the smaller
                // count digit sits on the title's baseline (not vertically
                // centered against it).
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(localized: "sidebar.archive.header", defaultValue: "Archive"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(String(localized: "sidebar.archive.header", defaultValue: "Archive"))
        .accessibilityValue(
            isCollapsed
                ? String(localized: "workspace.group.collapsed", defaultValue: "Collapsed")
                : String(localized: "workspace.group.expanded", defaultValue: "Expanded")
        )
        .contextMenu {
            Button(action: onToggle) {
                Label(
                    isCollapsed
                        ? String(localized: "sidebar.group.menu.expand", defaultValue: "Expand Group")
                        : String(localized: "sidebar.group.menu.collapse", defaultValue: "Collapse Group"),
                    systemImage: isCollapsed ? "chevron.down" : "chevron.right"
                )
            }
        }
    }
}
