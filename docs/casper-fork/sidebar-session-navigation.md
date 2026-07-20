# Sidebar session navigation, context menu, ordering

Three related sidebar/session features. The reopen-last-closed part of this patch was **retired** in the 2026-07 upstream merge — see the retirement note below. Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperSidebarNavigator.swift` (new) — rebuilds the displayed sidebar order and moves focus for ⌘↑/↓ (next/prev session) and ⌘⇧↑/↓ (next/prev workspace).
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `groups(from:)` now sorts rows *within* each folder group strictly by per-session recency (de-clump: a workspace's split-panels are no longer forced adjacent); added `CasperSidebarRowActions` bundle + the row `.contextMenu` (Rename / Pin / Duplicate / Open cwd / Reveal / Copy path / Close).
  - `Sources/Casper/Sidebar/CasperAgentActivity.swift` — added `compareEntryActivityDesc` (entry-level recency comparator).
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/KeyboardShortcutSettings.swift` — 4 new actions (`nextSession`/`prevSession`/`nextSessionWorkspace`/`prevSessionWorkspace`, default ⌘↑/↓ + ⌘⇧↑/↓); generalized the `reopenClosedBrowserPanel` label to "Reopen Closed Session".
  - `Sources/KeyboardShortcutContext.swift` — `.nonBrowserPanel` context for the 4 nav actions; `casperEventEditsTextInput(_:)` guard so ⌘↑/↓ stays text-nav in editing fields.
  - `Sources/AppDelegate.swift` — 4 nav dispatch arms (guarded by the text-input check) → `CasperSidebarNavigator`.
  - `Sources/ContentView.swift` — `VerticalTabsSidebar` builds `CasperSidebarRowActions` per row (`casperSidebarRowActions`/`casperSessionWorkingDirectory`), hoisted `let rowActions` to keep the row initializer type-checkable.
  - `cmux.xcodeproj/project.pbxproj` — new `CasperSidebarNavigator.swift` build entry.
  - `Resources/Localizable.xcstrings` — new shortcut + context-menu strings (en/ja); updated reopen label.
  - `web/data/cmux-shortcuts.ts`, `web/data/cmux.schema.json` — the 4 new shortcut actions added to the public shortcuts reference + the `cmux.json` schema enum (shortcut policy requires both).
- Notes:
  - ⌘↑/↓ and ⌘⇧↑/↓ intentionally shadow Ghostty's jump-to-prompt inside a focused terminal (cmux's local monitor intercepts first). The text-input guard preserves ⌘↑/↓ as move-to-start/end inside editing fields.
- **RETIRED (2026-07 merge): reopen-last-closed.** Upstream shipped `ClosedItemHistoryStore` + `AppDelegate.reopenMostRecentlyClosedItem` (panel/workspace/window) and a History menu, satisfying this patch's deletion condition. `casperRecentlyClosedItems`, `CasperClosedItem`, `casperReopenLastClosedItem`, and `ClosedBrowserPanelRestoreSnapshot.panelSnapshot` were deleted; ⌘⇧T, the command palette, and the menu all route to upstream's path. **Known gap:** upstream's history has no `.workspaceGroup` entry, so "Close All Sessions" now undoes one workspace at a time instead of as one step — see [sidebar group selection](sidebar-group-selection.md).
- Deletion condition:
  - Delete the remainder if upstream adds first-class sidebar row keyboard nav and per-session row ordering/context menus.
