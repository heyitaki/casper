# Debug-log gating for daily-driver DEBUG builds

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files (upstream files modified):
  - `Sources/FileDropOverlayViewHitTesting.swift` (`logHitTestDecision` guard requires an active capture/drag, not just lingering drag-pasteboard types)
  - `Sources/TerminalWindowPortal.swift` (`logDragRouteDecision` same stale-pasteboard guard fix)
  - `Sources/GhosttyTerminalView.swift` (`forceRefresh` skips logging healthy keystroke-driven refreshes; anomalous states and non-typing reasons still log)
- Summary:
  - The pinned Casper app is a DEBUG build used as a daily driver. The drag-routing debug logs gated on "drag pasteboard has relevant types" — but `NSPasteboard(.drag)` retains the last drag's types indefinitely, so after one file drag every keystroke/mouse-move paid a live `hitTest` + 6-level view-hierarchy walk + log write. `forceRefresh` additionally logged one line per keypress, growing `/tmp/cmux-debug-casper.log` into the millions of lines. All three sites keep their diagnostic value for actual drags / anomalous surface states.
- Deletion condition:
  - Delete if upstream rewrites the drag-overlay debug instrumentation or adds equivalent gating.
