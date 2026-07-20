# Minimal-mode sidebar

Minimal-presentation default, edge reveal strips, and the window-movable policy that keeps bonsplit tab drags working in minimal mode. Register index: [`docs/casper-fork.md`](../casper-fork.md).

## Minimal-mode sidebar and reveal strips

- Files (Casper-only): `Sources/Casper/Sidebar/SidebarRevealStrip.swift`, `AppDelegate+SidebarRevealEdgeMouseHandler.swift`, `WindowHostView+SidebarRevealPassThrough.swift`
- Files (upstream files modified — primary conflict surface):
  - `Sources/ContentView.swift` (reveal-strip wiring, zeroed traffic-light inset, conditional titlebar strip in minimal+collapsed mode)
  - `Sources/AppDelegate.swift` (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept)
  - `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift` (`hitTest()` pass-through bands)
  - `Sources/Update/UpdateTitlebarAccessory.swift` + `Sources/Update/MinimalModeSidebarControls.swift` + `Sources/WindowDragHandleView.swift` (trimmed sidebar-top button cluster, see merge note below; `CasperReloadTitlebarButton` injection; hint-interval shift via `TitlebarControlsLayoutMetrics.casperReloadButtonShift`)
  - `Sources/App/WorkspaceRuntimeSettings.swift` (default to minimal presentation)
  - `Resources/Localizable.xcstrings`
  - `cmuxTests/AppDelegateShortcutRoutingTests.swift`, `cmuxTests/InactivePaneFirstClickFocusTests.swift`
- Summary:
  - Workspace defaults to minimal presentation; hidden-sidebar gap replaced with a 5pt reveal strip on each edge (click expands sidebar, drag resizes window). `cmux_sendEvent` captures the click before AppKit resize tracking; portals pass through the same band.
  - 2026-06 merge note: upstream rewrote `TitlebarControlsView` (five buttons: toggle sidebar, new tab, notifications, focus-history back/forward; no `slots:` API). Casper trims the cluster to **New Tab + the DEBUG reload button** via `MinimalModeSidebarControlActionSlot.visibleSlots` (single source of truth, `[.newTab]` when branded). All consumers derive from it: `controlsGroup` rendering, `TitlebarControlsHitRegions` rect math (with `casperReloadButtonShift` so AppKit click targets align past the reload button), `computedHostWidth` (stock classic still = 164), and the hint-pill intervals (positions are visible-index based). Toggle sidebar / notifications / focus history are absent in branded builds — the edge reveal strip reopens the sidebar.
- Deletion condition:
  - Delete the intercept + pass-through when upstream adds equivalent edge-reveal affordances. Delete default-to-minimal if upstream adopts it.

## Minimal-mode window-movable policy

- Files (added): `Sources/Casper/Window/CasperMinimalModeWindowMovable.swift`
- Files (upstream files modified): `Sources/WindowDecorationsController.swift` (call after `applyMinimalModeSidebarTitlebarClickTarget(to:)` in `apply(to:)`), `Sources/ContentView.swift` (call after `configureCmuxMainWindowDragBehavior(window)` in the WindowAccessor refresh)
- Summary:
  - Forces `window.isMovable = false` on the main workspace window in minimal mode so AppKit's auto-titlebar-drag can't hijack bonsplit tab drags. Upstream's `configureCmuxMainWindowDragBehavior` and `WindowMoveSuppressionSequence` (depth-tracked, restores previous state) are compatible; the explicit call may now be partially redundant with upstream's drag behavior setup — re-evaluate at the next merge.
- Deletion condition:
  - Delete if upstream's main-window drag configuration provably covers minimal-mode bonsplit tab drags (verify by dragging a tab in a minimal-mode Casper build with the call removed).
