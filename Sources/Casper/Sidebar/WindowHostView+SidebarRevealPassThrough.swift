// CASPER: Hit-test pass-through + reveal-strip hover highlight, painted in
// AppKit ABOVE the hosted Metal surface so the highlight isn't occluded.

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

    /// Mouse-moved hook. Detects whether the cursor is in the leading or
    /// trailing reveal-strip band and paints the hover highlight as an
    /// AppKit subview layered ABOVE the hosted Metal surface (the SwiftUI
    /// strip overlay is occluded by the terminal's opaque Metal compositor
    /// so SwiftUI hover rendering doesn't suffice).
    func updateSidebarRevealHover(at point: NSPoint) {
        applySidebarRevealHover(in: self, at: point)
    }

    func clearSidebarRevealHover() {
        sidebarRevealHoverHighlights.setHover(leading: false, trailing: false)
        sidebarRevealRestoreArrowCursorIfOwned(host: self)
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

    func updateSidebarRevealHover(at point: NSPoint) {
        applySidebarRevealHover(in: self, at: point)
    }

    func clearSidebarRevealHover() {
        sidebarRevealHoverHighlights.setHover(leading: false, trailing: false)
        sidebarRevealRestoreArrowCursorIfOwned(host: self)
    }
}

/// Clear the AppKit reveal-strip hover highlight on every portal host attached
/// to `window`. Called when a sidebar transitions from hidden to visible (or
/// vice-versa) so the highlight disappears immediately instead of waiting for
/// the next `mouseMoved` event — without this, clicking the strip leaves the
/// tint painted on top of the newly-expanded sidebar until the user wiggles
/// the cursor.
@MainActor
func clearSidebarRevealHoverHighlights(in window: NSWindow) {
    guard let themeFrame = window.contentView?.superview else { return }
    for subview in themeFrame.subviews {
        if let terminal = subview as? WindowTerminalHostView {
            terminal.clearSidebarRevealHover()
        } else if let browser = subview as? WindowBrowserHostView {
            browser.clearSidebarRevealHover()
        }
    }
}

@MainActor
private func sidebarRevealMainWindowContext(in host: NSView) -> AppDelegate.MainWindowContext? {
    guard let window = host.window else { return nil }
    guard let appDelegate = AppDelegate.shared else { return nil }
    if let context = appDelegate.contextForMainTerminalWindow(window) {
        return context
    }
    // Fallback: identity scan (robust against `isMainTerminalWindow` predicate
    // returning false for transient sheet/key-window states).
    return appDelegate.mainWindowContexts.values.first(where: { $0.window === window })
}

@MainActor
private func applySidebarRevealHover(in host: NSView, at point: NSPoint) {
    let highlights = sidebarRevealHoverHighlights(in: host)
    let w = SidebarRevealStripMetrics.width
    let trailingX = host.bounds.maxX
    let inLeadingBand = point.x >= 0 && point.x < w
    let inTrailingBand = point.x > trailingX - w && point.x <= trailingX

    guard inLeadingBand || inTrailingBand else {
        highlights?.setHover(leading: false, trailing: false)
        sidebarRevealRestoreArrowCursorIfOwned(host: host)
        return
    }

    // CASPER: Gate hover on whether the host view abuts the window edge.
    // The strip is only rendered (and hover-able) on edges where the sidebar
    // is currently collapsed; on those edges the host extends all the way to
    // the window's content-view edge. Using slot-frame "flush" logic instead
    // misfires (browser focused → terminal portal has no visible slots →
    // hover never triggers even when the strip is in fact rendered).
    let leadingEdgeAtWindow: Bool
    let trailingEdgeAtWindow: Bool
    if let contentView = host.window?.contentView {
        let originInWindow = host.convert(NSPoint.zero, to: nil)
        let trailingInWindow = host.convert(NSPoint(x: host.bounds.maxX, y: 0), to: nil)
        let contentBoundsInWindow = contentView.convert(contentView.bounds, to: nil)
        leadingEdgeAtWindow = abs(originInWindow.x - contentBoundsInWindow.minX) <= 1
        trailingEdgeAtWindow = abs(trailingInWindow.x - contentBoundsInWindow.maxX) <= 1
    } else {
        leadingEdgeAtWindow = false
        trailingEdgeAtWindow = false
    }

    // CASPER: Sidebar-visibility gate. The reveal strip exists only to expand
    // a hidden sidebar; if the sidebar is already open there's nothing to
    // reveal, so the band must not paint hover or set the pointing-hand
    // cursor. Note: `leadingEdgeAtWindow` is NOT sufficient on its own — the
    // portal host is installed in the window's themeFrame at a frame matching
    // the entire content view, so it spans the full window width regardless of
    // sidebar visibility. The visibility check is the load-bearing gate.
    // Default to "assume visible" (suppress hover) when context lookup fails,
    // so a missing context can never produce a phantom expand-strip highlight
    // over an open sidebar.
    let context = sidebarRevealMainWindowContext(in: host)
    let leadingSidebarVisible = context?.sidebarState.isVisible ?? true
    let trailingSidebarVisible = context?.fileExplorerState?.isVisible ?? true
    let nextLeading = inLeadingBand && leadingEdgeAtWindow && !leadingSidebarVisible
    let nextTrailing = inTrailingBand && trailingEdgeAtWindow && !trailingSidebarVisible
    let wasHovering = highlights?.isHoveringEither ?? false
    highlights?.setHover(leading: nextLeading, trailing: nextTrailing)
    let isHovering = nextLeading || nextTrailing
    if isHovering && !wasHovering {
        SidebarRevealHoverCursorOwnership.acquire(host: host)
        NSCursor.pointingHand.set()
    } else if !isHovering && wasHovering {
        sidebarRevealRestoreArrowCursorIfOwned(host: host)
    }
}

/// Tracks which host (if any) most recently set the cursor to `pointingHand`
/// for a reveal-band hover. Used to avoid clobbering an arrow set by some
/// other path (e.g., a divider cursor or the terminal IBeam) when the reveal
/// band itself didn't establish the current cursor.
@MainActor
private enum SidebarRevealHoverCursorOwnership {
    static weak var owner: NSView?

    static func acquire(host: NSView) {
        owner = host
    }

    static func releaseIfOwned(host: NSView) -> Bool {
        guard owner === host else { return false }
        owner = nil
        return true
    }
}

@MainActor
private func sidebarRevealRestoreArrowCursorIfOwned(host: NSView) {
    guard SidebarRevealHoverCursorOwnership.releaseIfOwned(host: host) else { return }
    NSCursor.arrow.set()
}

@MainActor
private func sidebarRevealHoverHighlights(in host: NSView) -> SidebarRevealHoverHighlights? {
    if let terminal = host as? WindowTerminalHostView {
        return terminal.sidebarRevealHoverHighlights
    }
    if let browser = host as? WindowBrowserHostView {
        return browser.sidebarRevealHoverHighlights
    }
    return nil
}

/// Manages a pair of leading/trailing NSView overlays inside an AppKit
/// host view. The overlays are layer-backed and render the reveal-strip
/// hover tint above any hosted Metal surface. They are non-interactive
/// (hitTest returns nil) so they don't interfere with the host view's
/// pass-through hit-test routing.
@MainActor
final class SidebarRevealHoverHighlights {
    let leading = SidebarRevealHoverStripNSView()
    let trailing = SidebarRevealHoverStripNSView()

    /// Add the overlays as subviews of `host`, positioned at the top of the
    /// subview stack so they paint above everything else (including the
    /// hosted Metal surface). Idempotent.
    func install(in host: NSView) {
        if leading.superview !== host {
            host.addSubview(leading, positioned: .above, relativeTo: nil)
        }
        if trailing.superview !== host {
            host.addSubview(trailing, positioned: .above, relativeTo: nil)
        }
        layout(in: host)
    }

    /// Re-promote the overlays to the top of the subview stack so the host
    /// view's later-added subviews (e.g. the Ghostty surface scroll view)
    /// don't paint over them.
    func ensureOnTop(in host: NSView) {
        guard leading.superview === host || trailing.superview === host else { return }
        let subs = host.subviews
        guard subs.last !== trailing || subs.dropLast().last !== leading else { return }
        host.addSubview(leading, positioned: .above, relativeTo: nil)
        host.addSubview(trailing, positioned: .above, relativeTo: nil)
    }

    func layout(in host: NSView) {
        let w = SidebarRevealStripMetrics.width
        leading.frame = NSRect(x: 0, y: 0, width: w, height: host.bounds.height)
        trailing.frame = NSRect(
            x: host.bounds.maxX - w,
            y: 0,
            width: w,
            height: host.bounds.height
        )
    }

    func setHover(leading: Bool, trailing: Bool) {
        self.leading.isHovering = leading
        self.trailing.isHovering = trailing
    }

    var isHoveringEither: Bool {
        leading.isHovering || trailing.isHovering
    }
}

@MainActor
final class SidebarRevealHoverStripNSView: NSView {
    private static let hoverCGColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
    private static let clearCGColor = NSColor.clear.cgColor

    var isHovering: Bool = false {
        didSet {
            guard oldValue != isHovering else { return }
            applyHoverColor()
        }
    }

    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.clearCGColor
        // Pass all events through to the host view so its hitTest/cmux_sendEvent
        // routing for the reveal strip stays in charge of clicks/cursors.
        translatesAutoresizingMaskIntoConstraints = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = Self.clearCGColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyHoverColor() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = isHovering ? Self.hoverCGColor : Self.clearCGColor
        CATransaction.commit()
    }
}
