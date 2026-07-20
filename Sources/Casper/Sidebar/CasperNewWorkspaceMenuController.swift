// CASPER: shared AppKit directory menu for every sidebar new-workspace button.
// Delete if upstream adds a searchable recent-directory workspace menu.

import AppKit

@MainActor
final class CasperNewWorkspaceMenuController: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    private static let displayedRecentLimit = 7

    private let configuredItems: [CmuxResolvedConfigContextMenuItem]
    private let globalConfigPath: String?
    private let homeDirectory: String
    private let onConfiguredAction: (CmuxResolvedConfigAction) -> Bool
    private let onFolderPicker: () -> Void
    private let onRecentDirectory: (String) -> Void
    private let recentDirectories: [String]
    private let showsDirectoryItems: Bool

    private weak var activeMenu: NSMenu?
    private var configuredActions: [ObjectIdentifier: CmuxResolvedConfigAction] = [:]
    private var query = ""
    private weak var searchField: NSSearchField?
    private var searchItem: NSMenuItem?

    init(
        recentsStore: CasperRecentWorkspaceDirectoryStore = CasperRecentWorkspaceDirectoryStore(),
        configuredItems: [CmuxResolvedConfigContextMenuItem],
        globalConfigPath: String?,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        showsDirectoryItems: Bool,
        onRecentDirectory: @escaping (String) -> Void,
        onFolderPicker: @escaping () -> Void,
        onConfiguredAction: @escaping (CmuxResolvedConfigAction) -> Bool
    ) {
        self.recentDirectories = recentsStore.recentDirectories(limit: Self.displayedRecentLimit)
        self.configuredItems = configuredItems
        self.globalConfigPath = globalConfigPath
        self.homeDirectory = homeDirectory
        self.onRecentDirectory = onRecentDirectory
        self.onFolderPicker = onFolderPicker
        self.onConfiguredAction = onConfiguredAction
        self.showsDirectoryItems = showsDirectoryItems
    }

    /// - Parameter anchorRect: the button's rect in `anchorView`'s coordinates. When nil the
    ///   whole view is treated as the button, which anchors the menu to the view's leading
    ///   edge — correct only when the view is the button itself.
    func show(relativeTo anchorView: NSView, anchorRect: NSRect? = nil, event: NSEvent?) -> Bool {
        let hasConfiguredActions = configuredItems.contains(where: {
            if case .action = $0 { return true }
            return false
        })
        guard showsDirectoryItems || hasConfiguredActions else { return false }

        let menu = NSMenu()
        if showsDirectoryItems {
            menu.delegate = self
            activeMenu = menu
            let searchItem = makeSearchItem()
            self.searchItem = searchItem
            menu.addItem(searchItem)
            rebuildMenuItems(in: menu)
            let buttonRect = anchorRect ?? anchorView.bounds
            // popUp places the menu's top-left at this point. anchorView is unflipped, so
            // the button's bottom edge (minY) puts the menu below the button rather than
            // covering it.
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: buttonRect.minX, y: buttonRect.minY - 2),
                in: anchorView
            )
        } else {
            addConfiguredItems(to: menu, separatedFromExistingItems: false)
            // Assign delegate state only once the menu is certain to open: menuDidClose is
            // what clears it, and it never fires for a menu that was never shown.
            guard let event else { return false }
            menu.delegate = self
            activeMenu = menu
            NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let searchField = notification.object as? NSSearchField,
              let menu = activeMenu else {
            return
        }
        query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildMenuItems(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        searchField?.delegate = nil
        searchItem?.representedObject = nil
        menu.delegate = nil
        configuredActions.removeAll()
        activeMenu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        searchField?.window?.makeFirstResponder(searchField)
    }

    @objc private func chooseConfiguredAction(_ sender: NSMenuItem) {
        guard let action = configuredActions[ObjectIdentifier(sender)],
              onConfiguredAction(action) else {
            NSSound.beep()
            return
        }
    }

    @objc private func chooseFolderPicker(_ sender: NSMenuItem) {
        onFolderPicker()
    }

    @objc private func chooseRecentDirectory(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else {
            NSSound.beep()
            return
        }
        onRecentDirectory(directory)
    }

    private func abbreviatedPath(_ directory: String) -> String {
        if directory == homeDirectory {
            return "~"
        }
        let homePrefix = homeDirectory.hasSuffix("/") ? homeDirectory : homeDirectory + "/"
        guard directory.hasPrefix(homePrefix) else { return directory }
        return "~/" + directory.dropFirst(homePrefix.count)
    }

    private func addConfiguredItems(to menu: NSMenu, separatedFromExistingItems: Bool) {
        guard configuredItems.contains(where: {
            if case .action = $0 { return true }
            return false
        }) else {
            return
        }
        if separatedFromExistingItems {
            menu.addItem(.separator())
        }
        for configuredItem in configuredItems {
            switch configuredItem {
            case .separator:
                if menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
            case .action(let menuAction):
                let item = NSMenuItem(
                    title: menuAction.title,
                    action: #selector(chooseConfiguredAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = self
                item.toolTip = menuAction.tooltip
                if let globalConfigPath {
                    item.image = menuAction.icon?.contextMenuImage(
                        configSourcePath: menuAction.iconSourcePath,
                        globalConfigPath: globalConfigPath
                    )
                }
                if let stored = menuAction.action.menuShortcut,
                   let keyEquivalent = stored.menuItemKeyEquivalent {
                    item.keyEquivalent = keyEquivalent
                    item.keyEquivalentModifierMask = stored.modifierFlags
                }
                configuredActions[ObjectIdentifier(item)] = menuAction.action
                menu.addItem(item)
            }
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    private func makeSearchItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        let searchField = NSSearchField(frame: NSRect(x: 10, y: 4, width: 280, height: 28))
        searchField.autoresizingMask = [.width]
        searchField.placeholderString = String(
            localized: "sidebar.newWorkspace.searchFolders.placeholder",
            defaultValue: "Search folders…"
        )
        searchField.delegate = self
        container.addSubview(searchField)
        self.searchField = searchField

        let item = NSMenuItem()
        item.view = container
        item.representedObject = self
        return item
    }

    private func rebuildMenuItems(in menu: NSMenu) {
        while menu.items.count > 1 {
            menu.removeItem(at: 1)
        }
        configuredActions.removeAll(keepingCapacity: true)

        let header = NSMenuItem(
            title: String(localized: "sidebar.newWorkspace.recents", defaultValue: "Recents"),
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        for directory in filteredRecentDirectories() {
            let item = NSMenuItem(
                title: abbreviatedPath(directory),
                action: #selector(chooseRecentDirectory(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = directory
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let folderPicker = NSMenuItem(
            title: String(
                localized: "sidebar.newWorkspace.fromFolderPicker",
                defaultValue: "From Folder Picker…"
            ),
            action: #selector(chooseFolderPicker(_:)),
            keyEquivalent: ""
        )
        folderPicker.target = self
        folderPicker.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(folderPicker)
        addConfiguredItems(to: menu, separatedFromExistingItems: true)
    }

    private func filteredRecentDirectories() -> [String] {
        guard !query.isEmpty else { return recentDirectories }
        return recentDirectories.filter { directory in
            abbreviatedPath(directory).localizedCaseInsensitiveContains(query)
        }
    }
}
