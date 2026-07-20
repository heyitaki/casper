import AppKit
import SwiftUI

enum PanelCloseTabAction {
    @MainActor
    static func perform(workspaceId: UUID, panelId: UUID) {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: workspaceId) ?? app.tabManager else {
            return
        }
        manager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: panelId)
    }
}

@MainActor
enum PanelTabActions {
    static func splitHorizontally(workspaceId: UUID, panelId: UUID) {
        guard let manager = resolveManager(workspaceId: workspaceId) else { return }
        _ = manager.createSplit(tabId: workspaceId, surfaceId: panelId, direction: .down)
    }

    static func splitVertically(workspaceId: UUID, panelId: UUID) {
        guard let manager = resolveManager(workspaceId: workspaceId) else { return }
        _ = manager.createSplit(tabId: workspaceId, surfaceId: panelId, direction: .right)
    }

    static func newTab(workspaceId: UUID, panelId: UUID) {
        guard let manager = resolveManager(workspaceId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }),
              let paneId = workspace.paneId(forPanelId: panelId) else {
            return
        }
        workspace.clearSplitZoom()
        _ = workspace.newTerminalSurface(inPane: paneId, focus: true)
    }

    // CASPER: expose upstream Fork Conversation through panel-keyed menus;
    // delete if upstream adds sidebar/panel-body fork surfaces.
    static func canForkConversation(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = resolveManager(workspaceId: workspaceId)?
            .tabs.first(where: { $0.id == workspaceId }) else {
            return false
        }
        return workspace.canForkAgentConversationFromPanel(panelId)
    }

    static func forkConversation(
        workspaceId: UUID,
        panelId: UUID,
        destination: AgentConversationForkDestination?
    ) {
        guard let workspace = resolveManager(workspaceId: workspaceId)?
            .tabs.first(where: { $0.id == workspaceId }),
              workspace.forkAgentConversation(
                  fromPanelId: panelId,
                  destination: destination
              ) else {
            NSSound.beep()
            return
        }
    }

    static func canMoveTabToNewWorkspace(panelId: UUID) -> Bool {
        AppDelegate.shared?.canMoveSurfaceToNewWorkspace(panelId: panelId) ?? false
    }

    // CASPER: #3890 port — expose existing-workspace move targets so the unified
    // panel menu shows a "Move Tab" submenu with all workspaces, matching
    // GhosttyNSView+MoveTabToNewWorkspace upstream. Delete when upstream adds
    // a unified panel menu that covers browser/markdown/file-preview panels too.
    static func workspaceMoveTargets(panelId: UUID) -> [AppDelegate.WorkspaceMoveTarget] {
        guard let app = AppDelegate.shared else { return [] }
        return app.workspaceMoveTargets(forSurface: panelId)
    }

    static func moveTabToNewWorkspace(panelId: UUID) {
        guard canMoveTabToNewWorkspace(panelId: panelId) else {
            NSSound.beep()
            return
        }
        _ = AppDelegate.shared?.moveSurfaceToNewWorkspace(
            panelId: panelId,
            focus: true,
            focusWindow: false
        )
    }

    static func moveTabToWorkspace(panelId: UUID, workspaceId: UUID) {
        guard AppDelegate.shared?.moveSurface(
            panelId: panelId,
            toWorkspace: workspaceId,
            focus: true,
            focusWindow: true
        ) == true else {
            NSSound.beep()
            return
        }
    }

    static func closeTab(workspaceId: UUID, panelId: UUID) {
        PanelCloseTabAction.perform(workspaceId: workspaceId, panelId: panelId)
    }

    // CASPER: archive this one session (panel), or the whole workspace. Archive
    // is a Casper (compact-sidebar) feature, gated on `isBranded`. Delete with
    // the archive feature (`CasperArchiveStore`).
    static var archiveAvailable: Bool {
        CasperBuildEnvironment.isBranded
    }

    static func isSessionArchived(panelId: UUID) -> Bool {
        CasperArchiveStore.shared.isArchived(panelId)
    }

    static func toggleSessionArchive(panelId: UUID) {
        CasperArchiveStore.shared.toggle(panelId)
    }

    /// Terminal session ids in the panel's workspace (the same set the sidebar
    /// turns into rows).
    static func workspaceTerminalPanelIds(workspaceId: UUID) -> [UUID] {
        guard let workspace = resolveManager(workspaceId: workspaceId)?
            .tabs.first(where: { $0.id == workspaceId }) else {
            return []
        }
        return workspace.sidebarOrderedPanelIds().filter {
            workspace.panels[$0]?.panelType == .terminal
        }
    }

    static func canArchiveWorkspace(workspaceId: UUID) -> Bool {
        workspaceTerminalPanelIds(workspaceId: workspaceId).count > 1
    }

    static func archiveWorkspace(workspaceId: UUID) {
        CasperArchiveStore.shared.archivePanels(workspaceTerminalPanelIds(workspaceId: workspaceId))
    }

    private static func resolveManager(workspaceId: UUID) -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        return app.tabManagerFor(tabId: workspaceId) ?? app.tabManager
    }
}

@MainActor
final class PanelTabActionMenuController: NSObject {
    let workspaceId: UUID
    let panelId: UUID

    init(workspaceId: UUID, panelId: UUID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        super.init()
    }

    func appendActions(to menu: NSMenu) {
        let leadingNeedsSeparator = !menu.items.isEmpty
            && menu.items.last?.isSeparatorItem == false
        if leadingNeedsSeparator {
            menu.addItem(.separator())
        }

        let splitHItem = menu.addItem(
            withTitle: String(localized: "panelContextMenu.splitHorizontally", defaultValue: "Split Horizontally"),
            action: #selector(panelSplitHorizontally(_:)),
            keyEquivalent: ""
        )
        splitHItem.target = self
        splitHItem.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )
        applyConfiguredMenuShortcutIfAvailable(.splitDown, to: splitHItem)

        let splitVItem = menu.addItem(
            withTitle: String(localized: "panelContextMenu.splitVertically", defaultValue: "Split Vertically"),
            action: #selector(panelSplitVertically(_:)),
            keyEquivalent: ""
        )
        splitVItem.target = self
        splitVItem.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        applyConfiguredMenuShortcutIfAvailable(.splitRight, to: splitVItem)

        menu.addItem(.separator())

        let newTabItem = menu.addItem(
            withTitle: String(localized: "panelContextMenu.newTab", defaultValue: "New Tab"),
            action: #selector(panelNewTab(_:)),
            keyEquivalent: ""
        )
        newTabItem.target = self
        newTabItem.image = NSImage(
            systemSymbolName: "plus.rectangle.on.rectangle",
            accessibilityDescription: nil
        )

        menu.appendPanelCloseTabItem(
            target: self,
            action: #selector(panelCloseTab(_:))
        )

        // CASPER: mirror bonsplit's Fork Conversation presentation for all
        // panel-body menus; delete if upstream adds panel-body fork surfaces.
        appendForkConversationMenuItems(to: menu)

        appendMoveTabMenuItems(to: menu)

        // CASPER: archive is independent of whether any Move Tab destination
        // exists — must not live inside appendMoveTabMenuItems's early
        // returns (that nesting silently dropped Archive/Archive Workspace
        // for single-workspace users during the 2026-07 upstream merge).
        appendArchiveMenuItems(to: menu)
    }

    // CASPER: panel-body Fork Conversation delegates to Workspace's shared
    // panelId entry point; delete if upstream adds panel-body fork surfaces.
    private func appendForkConversationMenuItems(to menu: NSMenu) {
        guard PanelTabActions.canForkConversation(
            workspaceId: workspaceId,
            panelId: panelId
        ) else {
            return
        }

        menu.addItem(.separator())
        let forkItem = menu.addItem(
            withTitle: String(localized: "panelContextMenu.forkConversation", defaultValue: "Fork Conversation"),
            action: #selector(panelForkConversation(_:)),
            keyEquivalent: ""
        )
        forkItem.target = self
        forkItem.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: nil
        )

        let forkToItem = NSMenuItem(
            title: String(localized: "panelContextMenu.forkConversationTo", defaultValue: "Fork Conversation To"),
            action: nil,
            keyEquivalent: ""
        )
        let forkToMenu = NSMenu()
        forkToMenu.autoenablesItems = false
        let defaultDestination = AgentConversationForkDefaultSettings.current()
        for destination in AgentConversationForkDestination.allCases {
            if destination == .newTab {
                forkToMenu.addItem(.separator())
            }
            let destinationItem = NSMenuItem(
                title: destination.settingsTitle,
                action: #selector(panelForkConversationTo(_:)),
                keyEquivalent: ""
            )
            destinationItem.target = self
            destinationItem.representedObject = destination
            destinationItem.state = destination == defaultDestination ? .on : .off
            forkToMenu.addItem(destinationItem)
        }
        forkToItem.submenu = forkToMenu
        menu.addItem(forkToItem)
    }

    // CASPER: #3890 port — "Move Tab" submenu mirrors GhosttyNSView appendMoveCurrentSurfaceMoveMenuItems
    // but covers all panel types. Delete if upstream unifies terminal/browser/other panel menus.
    private func appendMoveTabMenuItems(to menu: NSMenu) {
        let canMoveToNewWorkspace = PanelTabActions.canMoveTabToNewWorkspace(panelId: panelId)
        let workspaceTargets = PanelTabActions.workspaceMoveTargets(panelId: panelId)
        guard canMoveToNewWorkspace || !workspaceTargets.isEmpty else { return }

        if workspaceTargets.isEmpty {
            // Only new-workspace is available — show a flat item.
            let moveItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace"),
                action: #selector(panelMoveTabToNewWorkspace(_:)),
                keyEquivalent: ""
            )
            moveItem.target = self
            moveItem.image = NSImage(
                systemSymbolName: "rectangle.portrait.and.arrow.right",
                accessibilityDescription: nil
            )
            return
        }

        // Multiple destinations — show a "Move Tab ▸" submenu.
        let topItem = NSMenuItem(
            title: String(localized: "terminalContextMenu.moveTab", defaultValue: "Move Tab"),
            action: nil,
            keyEquivalent: ""
        )
        topItem.image = NSImage(
            systemSymbolName: "rectangle.stack.badge.play",
            accessibilityDescription: nil
        )
        let submenu = NSMenu()
        if canMoveToNewWorkspace {
            let newWorkspaceItem = submenu.addItem(
                withTitle: String(localized: "terminalContextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace"),
                action: #selector(panelMoveTabToNewWorkspace(_:)),
                keyEquivalent: ""
            )
            newWorkspaceItem.target = self
            newWorkspaceItem.image = NSImage(
                systemSymbolName: "rectangle.portrait.and.arrow.right",
                accessibilityDescription: nil
            )
            submenu.addItem(.separator())
        }
        for target in workspaceTargets {
            let item = NSMenuItem(
                title: target.label,
                action: #selector(panelMoveTabToWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = target.workspaceId
            item.image = NSImage(
                systemSymbolName: "rectangle.portrait.on.rectangle.portrait",
                accessibilityDescription: nil
            )
            submenu.addItem(item)
        }
        topItem.submenu = submenu
        menu.addItem(topItem)
    }

    // CASPER: archive this one session (or, for multi-session workspaces, the
    // whole workspace). Independent of Move Tab's targets — must run
    // unconditionally from appendActions, not nested inside
    // appendMoveTabMenuItems, whose early returns (no targets / new-workspace
    // only) would otherwise skip it.
    private func appendArchiveMenuItems(to menu: NSMenu) {
        guard PanelTabActions.archiveAvailable else { return }
        menu.addItem(.separator())
        let archived = PanelTabActions.isSessionArchived(panelId: panelId)
        let archiveItem = menu.addItem(
            withTitle: archived
                ? String(localized: "sidebar.session.menu.unarchive", defaultValue: "Move to Active Sessions")
                : String(localized: "sidebar.session.menu.archive", defaultValue: "Archive Session"),
            action: #selector(panelToggleArchive(_:)),
            keyEquivalent: ""
        )
        archiveItem.target = self
        archiveItem.image = NSImage(
            systemSymbolName: archived ? "tray.and.arrow.up" : "archivebox",
            accessibilityDescription: nil
        )
        if !archived && PanelTabActions.canArchiveWorkspace(workspaceId: workspaceId) {
            let archiveWorkspaceItem = menu.addItem(
                withTitle: String(localized: "sidebar.session.menu.archiveWorkspace", defaultValue: "Archive Workspace"),
                action: #selector(panelArchiveWorkspace(_:)),
                keyEquivalent: ""
            )
            archiveWorkspaceItem.target = self
            archiveWorkspaceItem.image = NSImage(
                systemSymbolName: "archivebox.fill",
                accessibilityDescription: nil
            )
        }
    }

    private func applyConfiguredMenuShortcutIfAvailable(
        _ id: KeyboardShortcutSettings.Action,
        to item: NSMenuItem
    ) {
        let stored = KeyboardShortcutSettings.menuShortcut(for: id)
        guard let keyEquivalent = stored.menuItemKeyEquivalent else { return }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = stored.modifierFlags
    }

    @objc private func panelSplitHorizontally(_ sender: Any?) {
        PanelTabActions.splitHorizontally(workspaceId: workspaceId, panelId: panelId)
    }

    @objc private func panelSplitVertically(_ sender: Any?) {
        PanelTabActions.splitVertically(workspaceId: workspaceId, panelId: panelId)
    }

    @objc private func panelNewTab(_ sender: Any?) {
        PanelTabActions.newTab(workspaceId: workspaceId, panelId: panelId)
    }

    @objc private func panelCloseTab(_ sender: Any?) {
        PanelTabActions.closeTab(workspaceId: workspaceId, panelId: panelId)
    }

    // CASPER: selectors for the shared panel-keyed fork action; delete if
    // upstream adds panel-body Fork Conversation surfaces.
    @objc private func panelForkConversation(_ sender: Any?) {
        PanelTabActions.forkConversation(
            workspaceId: workspaceId,
            panelId: panelId,
            destination: nil
        )
    }

    @objc private func panelForkConversationTo(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let destination = item.representedObject as? AgentConversationForkDestination else {
            NSSound.beep()
            return
        }
        PanelTabActions.forkConversation(
            workspaceId: workspaceId,
            panelId: panelId,
            destination: destination
        )
    }

    @objc private func panelMoveTabToNewWorkspace(_ sender: Any?) {
        PanelTabActions.moveTabToNewWorkspace(panelId: panelId)
    }

    @objc private func panelMoveTabToWorkspace(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let targetWorkspaceId = item.representedObject as? UUID else {
            NSSound.beep()
            return
        }
        PanelTabActions.moveTabToWorkspace(panelId: panelId, workspaceId: targetWorkspaceId)
    }

    @objc private func panelToggleArchive(_ sender: Any?) {
        PanelTabActions.toggleSessionArchive(panelId: panelId)
    }

    @objc private func panelArchiveWorkspace(_ sender: Any?) {
        PanelTabActions.archiveWorkspace(workspaceId: workspaceId)
    }
}

private var panelTabActionMenuControllerKey: UInt8 = 0

extension NSMenu {
    @discardableResult
    func appendPanelCloseTabItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = addItem(
            withTitle: String(localized: "menu.file.closeTab", defaultValue: "Close Tab"),
            action: action,
            keyEquivalent: ""
        )
        item.target = target
        let stored = KeyboardShortcutSettings.menuShortcut(for: .closeTab)
        if let keyEquivalent = stored.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = stored.modifierFlags
        }
        item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        return item
    }

    @MainActor
    func appendPanelTabActions(workspaceId: UUID, panelId: UUID) {
        let controller = PanelTabActionMenuController(workspaceId: workspaceId, panelId: panelId)
        objc_setAssociatedObject(
            self,
            &panelTabActionMenuControllerKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        controller.appendActions(to: self)
    }
}

private struct PanelTabActionsContextMenu: ViewModifier {
    let workspaceId: UUID
    let panelId: UUID

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                PanelTabActions.splitHorizontally(workspaceId: workspaceId, panelId: panelId)
            } label: {
                Text(String(localized: "panelContextMenu.splitHorizontally", defaultValue: "Split Horizontally"))
            }
            .keyboardShortcut(splitHShortcut)

            Button {
                PanelTabActions.splitVertically(workspaceId: workspaceId, panelId: panelId)
            } label: {
                Text(String(localized: "panelContextMenu.splitVertically", defaultValue: "Split Vertically"))
            }
            .keyboardShortcut(splitVShortcut)

            Divider()

            Button {
                PanelTabActions.newTab(workspaceId: workspaceId, panelId: panelId)
            } label: {
                Text(String(localized: "panelContextMenu.newTab", defaultValue: "New Tab"))
            }

            Button {
                PanelTabActions.closeTab(workspaceId: workspaceId, panelId: panelId)
            } label: {
                Text(String(localized: "menu.file.closeTab", defaultValue: "Close Tab"))
            }
            .keyboardShortcut(closeTabShortcut)

            // CASPER: mirror bonsplit's Fork Conversation presentation for the
            // SwiftUI panel menu; delete if upstream adds panel-body fork surfaces.
            if PanelTabActions.canForkConversation(workspaceId: workspaceId, panelId: panelId) {
                Divider()
                Button {
                    PanelTabActions.forkConversation(
                        workspaceId: workspaceId,
                        panelId: panelId,
                        destination: nil
                    )
                } label: {
                    Label(
                        String(localized: "panelContextMenu.forkConversation", defaultValue: "Fork Conversation"),
                        systemImage: "arrow.triangle.branch"
                    )
                }

                let defaultForkDestination = AgentConversationForkDefaultSettings.current()
                Menu(String(localized: "panelContextMenu.forkConversationTo", defaultValue: "Fork Conversation To")) {
                    ForEach(AgentConversationForkDestination.allCases) { destination in
                        if destination == .newTab {
                            Divider()
                        }
                        Button {
                            PanelTabActions.forkConversation(
                                workspaceId: workspaceId,
                                panelId: panelId,
                                destination: destination
                            )
                        } label: {
                            if destination == defaultForkDestination {
                                Label(destination.settingsTitle, systemImage: "checkmark")
                            } else {
                                Text(destination.settingsTitle)
                            }
                        }
                    }
                }
            }

            // CASPER: #3890 port — submenu mirrors the AppKit version above.
            // Delete if upstream unifies panel context menus.
            let workspaceTargets = PanelTabActions.workspaceMoveTargets(panelId: panelId)
            let canMoveToNewWorkspace = PanelTabActions.canMoveTabToNewWorkspace(panelId: panelId)
            if canMoveToNewWorkspace || !workspaceTargets.isEmpty {
                if workspaceTargets.isEmpty {
                    Button {
                        PanelTabActions.moveTabToNewWorkspace(panelId: panelId)
                    } label: {
                        Text(String(localized: "terminalContextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace"))
                    }
                } else {
                    Menu(String(localized: "terminalContextMenu.moveTab", defaultValue: "Move Tab")) {
                        if canMoveToNewWorkspace {
                            Button {
                                PanelTabActions.moveTabToNewWorkspace(panelId: panelId)
                            } label: {
                                Text(String(localized: "terminalContextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace"))
                            }
                            Divider()
                        }
                        ForEach(workspaceTargets) { target in
                            Button {
                                PanelTabActions.moveTabToWorkspace(panelId: panelId, workspaceId: target.workspaceId)
                            } label: {
                                Text(target.label)
                            }
                        }
                    }
                }
            }

            // CASPER: archive this one session (or, for multi-session
            // workspaces, the whole workspace).
            if PanelTabActions.archiveAvailable {
                Divider()
                Button {
                    PanelTabActions.toggleSessionArchive(panelId: panelId)
                } label: {
                    Text(
                        PanelTabActions.isSessionArchived(panelId: panelId)
                            ? String(localized: "sidebar.session.menu.unarchive", defaultValue: "Move to Active Sessions")
                            : String(localized: "sidebar.session.menu.archive", defaultValue: "Archive Session")
                    )
                }
                if !PanelTabActions.isSessionArchived(panelId: panelId)
                    && PanelTabActions.canArchiveWorkspace(workspaceId: workspaceId) {
                    Button {
                        PanelTabActions.archiveWorkspace(workspaceId: workspaceId)
                    } label: {
                        Text(String(localized: "sidebar.session.menu.archiveWorkspace", defaultValue: "Archive Workspace"))
                    }
                }
            }
        }
    }

    private var splitHShortcut: KeyboardShortcut? {
        shortcutValue(for: .splitDown)
    }

    private var splitVShortcut: KeyboardShortcut? {
        shortcutValue(for: .splitRight)
    }

    private var closeTabShortcut: KeyboardShortcut {
        shortcutValue(for: .closeTab) ?? KeyboardShortcut("w", modifiers: .command)
    }

    private func shortcutValue(for id: KeyboardShortcutSettings.Action) -> KeyboardShortcut? {
        let stored = KeyboardShortcutSettings.shortcut(for: id)
        guard let key = stored.keyEquivalent else { return nil }
        return KeyboardShortcut(key, modifiers: stored.eventModifiers)
    }
}

extension View {
    func panelTabActionsContextMenu(workspaceId: UUID, panelId: UUID) -> some View {
        modifier(PanelTabActionsContextMenu(workspaceId: workspaceId, panelId: panelId))
    }
}
