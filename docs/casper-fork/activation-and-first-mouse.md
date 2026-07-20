# Activation and first-mouse click handling

Two related patches around upstream's #3856 first-mouse gate: scoping the gate to true app-activation clicks, and repairing the AppKit activation desync that made the gate swallow clicks indefinitely. Register index: [`docs/casper-fork.md`](../casper-fork.md).

## First-mouse gate scoped to app-activation clicks

- Files (upstream files modified):
  - `Sources/App/CmuxMainWindow.swift` (`shouldCaptureInactiveFirstMouse` routes through new `FirstMouseGatePolicy.shouldCapture`, which additionally requires `NSApp.keyWindow == nil`)
  - `Sources/Casper/Sidebar/AppDelegate+SidebarRevealEdgeMouseHandler.swift` (DEBUG `sidebar.click.context` forensics log on every sidebar-band leftMouseDown, recording pre-dispatch key/active state)
- Summary:
  - Upstream's #3856 first-mouse gate (`FirstMouseGatedHostingOverlay` covering the whole sidebar) swallowed clicks whenever the main window wasn't key. When an in-app panel held key (notifications popover, command palette, two-phase activation restore), that turned the sidebar into a click dead zone until the main window regained key — observed in the field as "temporarily unable to switch sessions by clicking (plain/shift/cmd)". `NSApp.keyWindow == nil` discriminates true app-activation clicks (gate them, per #3856 intent) from in-app key borrowing (pass through).
- Deletion condition:
  - Delete if upstream scopes the gate to app-activation clicks (or removes the overlay).

## Activation-desync repair

Sidebar dead until Space switch.

- Files:
  - `Sources/Casper/Sidebar/AppDelegate+CasperActivationDesyncRepair.swift` (new; `CasperActivationDesyncRepairPolicy` + repair hook)
  - `Sources/AppDelegate.swift` (upstream file; one CASPER-marked call into the repair in the window `cmux_sendEvent` leftMouseDown routing — placed after the chrome/reveal-strip interceptors so `makeKey()`'s deferred `didBecomeKey` work can't interleave with their `nextEvent` tracking loops)
  - `Sources/TerminalNotificationStore.swift` (upstream file; `AppFocusState.isAppActive()` falls back to `NSRunningApplication.current.isActive` so `.activeFocus` badge dismissal isn't dropped while desynced)
  - `Sources/Casper/Sidebar/AppDelegate+SidebarRevealEdgeMouseHandler.swift` (forensics log gains `sysActive`/`mods` fields)
- Summary:
  - Field forensics (2026-07, /tmp/cmux-debug-casper.log) showed multi-minute "sidebar dead" episodes where every sidebar click arrived with `key=0 main=0 appActive=0` while arrow-key events were still being delivered and consumed by the file explorer — i.e. the OS considered the app active while AppKit's `NSApp.isActive` was stuck false (missed `didBecomeActive`). In that state AppKit treats each click as an app-activation click, the system-side activation request no-ops ("already active"), no `didBecomeKey` ever fires, and the #3856 first-mouse gate swallows every click until the user forces a real deactivate→activate cycle (Space switch). The repair runs on leftMouseDown at main workspace windows when `NSApp.isActive == false`: it re-requests activation, and — only when `NSRunningApplication.current.isActive` proves the desync — restores key/main status directly so the same click already sees a key window. Genuine background clicks keep upstream's first-click-swallow UX.
- Deletion condition:
  - Delete if upstream resyncs `NSApp.isActive` after a missed `didBecomeActive` (or macOS fixes the cooperative-activation desync).
