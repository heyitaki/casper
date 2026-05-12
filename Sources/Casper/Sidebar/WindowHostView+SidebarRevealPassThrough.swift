// CASPER: Hit-test pass-through so AppKit terminal/browser hosts don't swallow
// clicks landing on the leading/trailing SwiftUI reveal strips. Delete this
// file if upstream lands a comparable reveal affordance.
//
// Hot path: called inline from `WindowTerminalHostView.hitTest()` and
// `WindowBrowserHostView.hitTest()` on every event, including keyboard.
// The leading guard exits fast (constant-time) when the click isn't in
// the reveal band; only then do we walk subviews.

import AppKit

/// When either sidebar is hidden, that edge of the window hosts a thin
/// SwiftUI reveal strip. Without this pass-through, the AppKit portal sits
/// above the strip and swallows mouse-down clicks (hover leaks through), so
/// clicking the strip never re-expands the sidebar.
private func sidebarRevealStripPassThroughIsActive<Slot: NSView>(
    in host: NSView,
    at point: NSPoint,
    slotType: Slot.Type
) -> Bool {
    let w = SidebarRevealStripMetrics.width
    guard point.x < w || point.x > host.bounds.maxX - w else { return false }
    let frames = host.subviews.compactMap { $0 as? Slot }
        .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }
        .map { $0.frame }
    return SidebarRevealStripMetrics.shouldPassThrough(
        point: point,
        bounds: host.bounds,
        hostedFrames: frames
    )
}

extension WindowTerminalHostView {
    func shouldPassThroughToSidebarRevealStrip(at point: NSPoint) -> Bool {
        sidebarRevealStripPassThroughIsActive(
            in: self,
            at: point,
            slotType: GhosttySurfaceScrollView.self
        )
    }
}

extension WindowBrowserHostView {
    func shouldPassThroughToSidebarRevealStrip(at point: NSPoint) -> Bool {
        sidebarRevealStripPassThroughIsActive(
            in: self,
            at: point,
            slotType: WindowBrowserSlotView.self
        )
    }
}
