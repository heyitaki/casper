# Sidebar and panel-menu "Fork Conversation" surfaces

Register index: [`docs/casper-fork.md`](../casper-fork.md).

Adds upstream's **Fork Conversation** presentation to the Casper session-row context menu and the unified panel right-click menu. Both surfaces show a primary action that uses the configured default destination plus a **Fork Conversation To** submenu containing Right Split, Left Split, Top Split, Bottom Split, New Tab, and New Workspace, with the configured default checkmarked. Visibility and execution use upstream's synchronous `.supportedWithoutProbe` snapshot gate, so plain terminals, unsupported agents, and snapshots requiring an asynchronous probe do not advertise a fork that may fail silently.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `CasperSidebarPanelEntry.canForkConversation` carries the immutable availability snapshot and participates in row equality; `CasperSidebarRowActions.onForkConversation` carries the optional destination action; the row menu mirrors bonsplit's primary item and six-destination submenu without holding a workspace/store reference below the list snapshot boundary.
  - `Sources/Casper/Sidebar/CasperSidebarActivityRefresher.swift` — forwards `SharedLiveAgentIndex.objectWillChange` into the sidebar's throttled refresh so a live agent whose snapshot first lands via the background index load surfaces the fork item without waiting for an unrelated repaint (the branded sidebar observes no `Workspace`, so upstream's index→workspace forwarding never reaches it).
- Upstream files modified (all new hunks `// CASPER:`-marked):
  - `Sources/Workspace.swift` — adds the small panel-ID-keyed `forkAgentConversation(fromPanelId:destination:)` entry point, which resolves the upstream snapshot/gate, tab/pane anchors, default setting, and existing private destination dispatcher.
  - `Sources/Panels/PanelCloseTabContextMenu.swift` — AppKit and SwiftUI panel menus share `PanelTabActions.forkConversation`; both render the primary item and destination submenu.
  - `Sources/ContentView.swift` — stamps upstream fork availability into each immutable sidebar entry and wires the row action to `PanelTabActions`.
  - `Resources/Localizable.xcstrings` — adds `panelContextMenu.forkConversation` and `panelContextMenu.forkConversationTo` (en/ja), shared by both surfaces.
  - `cmux.xcodeproj/project.pbxproj` — removes the deleted bespoke `CasperForkSession.swift` entries.
  - `cmuxTests/WorkspaceUnitTests.swift` — CASPER-marked tests for the panel-ID bridge (default-destination, no-snapshot, probe-required, new-workspace) plus the refresher index-publish test.
  - `cmuxTests/AppDelegateShortcutRoutingTests.swift` — minimal shim update for the renamed row action and a `canForkConversation` row-equality assertion (existing-test upkeep, no new CASPER surface).
- Notes:
  - `CasperForkSession.swift` and its PID-liveness/disk-index/alert path are retired; upstream's `SharedLiveAgentIndex`, restored snapshots, fork command builder, destination dispatcher, and owning-`TabManager` new-workspace path now own the behavior end to end.
  - Keeping `canForkConversation` on the entry instead of the closure bundle is required for `CasperSidebarPanelRow ==` to invalidate when the upstream gate changes.
- Deletion condition: remove the panel-ID bridge and Casper menu wiring if upstream adds sidebar and panel-body Fork Conversation surfaces.
