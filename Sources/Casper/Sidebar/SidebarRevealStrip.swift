// CASPER: Sidebar reveal-strip + edge-resize helpers for minimal-mode hidden-sidebar affordance.

import AppKit
import Combine
import SwiftUI

struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

/// Sizing for the sidebar reveal strip. Lives outside the SwiftUI view so the
/// portal hit-test (`TerminalWindowPortal.swift`) can pass-through the same
/// region without depending on SwiftUI.
enum SidebarRevealStripMetrics {
    static let width: CGFloat = 5
    static let tapThreshold: CGFloat = 3
    static let leadingEdgeEpsilon: CGFloat = 1
    static let minimumLeadingContentWidth: CGFloat = 24

    /// Tab-bar bottom-separator inset to apply on the side facing a reveal strip:
    /// `width` when the sidebar is hidden (so the hairline doesn't paint through
    /// the strip column), `0` otherwise.
    static func separatorInset(sidebarVisible: Bool) -> CGFloat {
        sidebarVisible ? 0 : width
    }

    /// Shift+click must bypass the reveal-strip mouse-down intercept entirely:
    /// ghostty's convention for selecting text while a TUI captures the mouse
    /// is shift+drag, and a selection starting in the leftmost terminal column
    /// lands inside the reveal band. Shared by both edge handlers in
    /// `AppDelegate+SidebarRevealEdgeMouseHandler.swift`.
    static func shouldBypassRevealIntercept(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.shift)
    }

    /// Shared sidebar-hidden detector for `WindowTerminalHostView` and
    /// `WindowBrowserHostView` hit-tests: if a hosted view is flush to either
    /// edge of `bounds`, treat clicks in the matching reveal band as
    /// pass-through so the SwiftUI `SidebarRevealStripView` underneath gets
    /// the click.
    static func shouldPassThrough(
        point: NSPoint,
        bounds: CGRect,
        hostedFrames: [CGRect]
    ) -> Bool {
        let inLeadingBand = point.x >= 0 && point.x < width
        let trailingX = bounds.maxX
        let inTrailingBand = point.x > trailingX - width && point.x <= trailingX
        guard inLeadingBand || inTrailingBand else { return false }
        if inLeadingBand && hostedFrames.contains(where: {
            $0.minX <= leadingEdgeEpsilon && $0.maxX > minimumLeadingContentWidth
        }) {
            return true
        }
        if inTrailingBand && hostedFrames.contains(where: {
            (trailingX - $0.maxX) <= leadingEdgeEpsilon && $0.width > minimumLeadingContentWidth
        }) {
            return true
        }
        return false
    }
}

enum SidebarRevealEdgeGeometry {
    /// Compute the new window frame when the user drags the reveal-strip
    /// resize band. `draggedEdge` is the edge of the window being dragged:
    /// `.leading` keeps the right edge fixed; `.trailing` keeps the left
    /// edge fixed.
    static func resizedFrame(
        startFrame: NSRect,
        dxScreen: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        draggedEdge: SidebarResizeInteraction.Edge
    ) -> NSRect {
        switch draggedEdge {
        case .leading:
            let rightEdge = startFrame.maxX
            let proposedWidth = rightEdge - (startFrame.origin.x + dxScreen)
            let clampedWidth = min(maxWidth, max(minWidth, proposedWidth))
            return NSRect(
                x: rightEdge - clampedWidth,
                y: startFrame.origin.y,
                width: clampedWidth,
                height: startFrame.height
            )
        case .trailing:
            let proposedWidth = startFrame.width + dxScreen
            let clampedWidth = min(maxWidth, max(minWidth, proposedWidth))
            return NSRect(
                x: startFrame.origin.x,
                y: startFrame.origin.y,
                width: clampedWidth,
                height: startFrame.height
            )
        }
    }
}

/// Thin strip docked at the leading or trailing edge while the matching
/// sidebar is hidden. Clicks (including on the edge resize hit zone) are
/// intercepted in `cmux_sendEvent` BEFORE AppKit's resize tracking starts —
/// see `AppDelegate.handleSidebarRevealLeadingEdgeMouseDown(window:event:)`.
///
/// CASPER: The hover tint is painted exclusively by the AppKit overlay
/// `SidebarRevealHoverStripNSView` (installed in the portal host above the
/// Metal compositor). Painting it here as well would double up over the
/// portion of the strip column that sits below the SwiftUI tab bar (since
/// AppKit overlay + SwiftUI overlay both apply 0.16 alpha), making the strip
/// look darker over the tab bar than over the terminal area. Keep this
/// SwiftUI strip purely as a click/help/a11y participant.
struct SidebarRevealStripView: View {
    let label: String

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
    }
}
