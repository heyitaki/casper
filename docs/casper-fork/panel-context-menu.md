# Panel right-click context menu unification (+ #3890 parity)

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files added: `Sources/Panels/PanelCloseTabContextMenu.swift`
- Files (upstream files modified): `Sources/GhosttyTerminalView.swift` (rightMouseDown forwarding under mouse capture; `appendPanelTabActions` replaces upstream's `appendMoveCurrentSurfaceMoveMenuItems`), `Sources/Panels/CmuxWebView.swift`, `BrowserPanel.swift`, `MarkdownPanelView.swift`, `FilePreviewPanel.swift`, `FilePreviewTextEditor.swift`, `FilePreviewMagnifyingPDFView.swift`, `Sources/AppDelegate.swift` + `Sources/CmuxConfig.swift` + `Sources/CmuxSurfaceTabBarBuiltInAction.swift` (shortcut display via `menuShortcut`)
- Files removed (relative to upstream): `CmuxWebView+CloseTab.swift`, `CmuxWebView+MoveTabToNewWorkspace.swift`, `BrowserPanel+CloseTab.swift`, `BrowserPanel+MoveTabToNewWorkspace.swift`, `GhosttyNSView+MoveTabToNewWorkspace.swift`
- Summary:
  - Single shared menu path for Split/New Tab/Close Tab/Move Tab across all panels. Upstream #3890 ("move tab into existing workspace" submenu) was ported into `PanelTabActions`/`PanelTabActionMenuController` during the 2026-06 merge so all panels get it, using upstream's `terminalContextMenu.moveTab*` strings.
  - Terminal right-click under mouse capture (vim `mouse=a`, tmux) forwards PRESS+RELEASE to the PTY and still presents the menu.
- Deletion condition:
  - If upstream unifies its per-panel menu duplication, fold into theirs and keep only `menuShortcut` plumbing.
