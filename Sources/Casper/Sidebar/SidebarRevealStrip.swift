// CASPER: Sidebar reveal-strip + edge-resize helpers added for minimal-mode polish.
// Delete if upstream lands a comparable hidden-sidebar reveal affordance.
//
// Consumed by:
//   - Sources/ContentView.swift (overlay rendering + resizer accessibility)
//   - Sources/TerminalWindowPortal.swift (hit-test pass-through)
//   - Sources/BrowserWindowPortal.swift (hit-test pass-through)
//   - Sources/AppDelegate.swift (cmux_sendEvent reveal-edge mouse-down intercept)
//   - cmuxTests/AppDelegateShortcutRoutingTests.swift (regression coverage)

import AppKit
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

/// Thin strip docked at the leading edge while the sidebar is hidden.
/// Clicks (including on the leading-edge resize hit zone) are intercepted in
/// `cmux_sendEvent` BEFORE AppKit's resize tracking starts — see
/// `AppDelegate.handleSidebarRevealLeadingEdgeMouseDown(window:event:)`.
/// SwiftUI hover is reliable for the highlight affordance because hover
/// events fire normally before any tracking session begins.
struct SidebarRevealStripView: View {
    let label: String

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.primary.opacity(0.16) : Color.primary.opacity(0.001))
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help(label)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
    }
}
