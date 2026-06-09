import AppKit
import SwiftUI

final class MainWindowHostingView<Content: View>: NSHostingView<Content> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    deinit {}

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class FirstMouseGatedHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if shouldCaptureInactiveFirstMouse(at: point) {
            return self
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    func shouldCaptureInactiveFirstMouse(at point: NSPoint) -> Bool {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return FirstMouseGatePolicy.shouldCapture(
            windowIsKey: window?.isKeyWindow == true,
            appHasKeyWindow: NSApp.keyWindow != nil,
            paneFirstClickFocusEnabled: PaneFirstClickFocusSettings.isEnabled(),
            containsPoint: bounds.contains(localPoint)
        )
    }
}

/// Decision for the first-mouse gate (#3856): swallow the click that
/// activates the app so it doesn't also focus a pane / fire a sidebar row.
enum FirstMouseGatePolicy {
    static func shouldCapture(
        windowIsKey: Bool,
        appHasKeyWindow: Bool,
        paneFirstClickFocusEnabled: Bool,
        containsPoint: Bool
    ) -> Bool {
        // CASPER: gate only true app-activation clicks. When ANOTHER window of
        // this app holds key (notifications popover, command palette, the
        // two-phase activation restore), the old `!windowIsKey` predicate
        // swallowed EVERY sidebar click until the main window regained key —
        // a "sidebar stops responding to clicks" dead zone. `appHasKeyWindow`
        // distinguishes the two: NSApp.keyWindow is nil while the app is
        // inactive (the case this gate exists for) and non-nil when an
        // in-app panel merely borrowed key status. Delete if upstream scopes
        // the gate to app-activation clicks itself.
        !windowIsKey &&
            !appHasKeyWindow &&
            !paneFirstClickFocusEnabled &&
            containsPoint
    }
}

final class FirstMouseGatedPassThroughHostingView<Content: View>: FirstMouseGatedHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldCaptureInactiveFirstMouse(at: point) ? self : nil
    }
}

struct FirstMouseGatedHostingOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> FirstMouseGatedPassThroughHostingView<AnyView> {
        FirstMouseGatedPassThroughHostingView(rootView: AnyView(EmptyView()))
    }

    func updateNSView(_ nsView: FirstMouseGatedPassThroughHostingView<AnyView>, context: Context) {
        nsView.rootView = AnyView(EmptyView())
    }
}

@MainActor
final class CmuxMainWindow: NSWindow {
    private var isSoftHiddenForVisibilityController = false

    func setSoftHiddenForVisibilityController(_ isSoftHidden: Bool) {
        isSoftHiddenForVisibilityController = isSoftHidden
        if isSoftHidden {
            makeFirstResponder(nil)
            ignoresMouseEvents = true
            alphaValue = 0
        } else {
            alphaValue = 1
            ignoresMouseEvents = false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.flagsChanged(with: event)
    }
}

extension CmuxMainWindow {
    private static let defaultContentSize = NSSize(width: 1_000, height: 700)

    /// Returns an unpositioned content rect clamped to the visible display; callers own final placement.
    static func defaultContentRect(styleMask: NSWindow.StyleMask) -> NSRect {
        let unpositionedContentRect = NSRect(origin: .zero, size: defaultContentSize)
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return unpositionedContentRect
        }

        let frameRect = NSWindow.frameRect(forContentRect: unpositionedContentRect, styleMask: styleMask)
        let clampedFrameRect = clampedFrame(frameRect, within: visibleFrame)
        return NSWindow.contentRect(forFrameRect: clampedFrameRect, styleMask: styleMask)
    }

    private static func clampedFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let width = min(max(frame.width, defaultContentSize.width), visibleFrame.width)
        let height = min(max(frame.height, defaultContentSize.height), visibleFrame.height)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}
