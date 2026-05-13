// CASPER: AppKit portal layer for the Casper code editor. Hosts
// TextViewController views above SwiftUI so they survive workspace remounts
// and pane drags without lifecycle teardown. Delete if upstream adds an editor
// portal layer like TerminalWindowPortal.

import AppKit
import ObjectiveC

private var casperEditorPortalKey: UInt8 = 0
private var casperEditorPortalCloseObserverKey: UInt8 = 0

/// Transparent host view installed above SwiftUI's content view. Editor views
/// live as its subviews. Returns nil from hitTest when the point is not over a
/// hosted editor so dividers, chrome, and terminal portal pass-through still
/// route correctly.
final class CasperEditorHostView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
final class CasperEditorPortal: NSObject {
    private weak var window: NSWindow?
    private let hostView = CasperEditorHostView(frame: .zero)
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var installConstraints: [NSLayoutConstraint] = []
    private var geometryObservers: [NSObjectProtocol] = []

    private struct Entry {
        weak var hostedView: NSView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
    }

    private var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        installGeometryObservers(for: window)
        _ = ensureInstalled()
    }

    private func installGeometryObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeAll() }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeAll() }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = note.object as? NSSplitView,
                      splitView.window === self.window else { return }
                self.synchronizeAll()
            }
        })
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            hostView.removeFromSuperview()
            // Install above contentView so editor views render over SwiftUI.
            // Keep below any later-added portal hosts (terminal, browser) — those
            // hosts pass through hit tests when their subviews aren't hit, so
            // pointer events still reach editor views beneath them.
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = container
            installedReferenceView = reference
        }
        return true
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        if let glassTarget = WindowGlassEffect.portalInstallationTarget(for: window) {
            return glassTarget
        }
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    func bind(hostedView: NSView, to anchorView: NSView, visibleInUI: Bool) {
        guard ensureInstalled() else { return }
        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)

        // If another hosted view was bound to this anchor, detach it.
        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
            if let prev = entriesByHostedId.removeValue(forKey: previousHostedId),
               let prevView = prev.hostedView,
               prevView.superview === hostView {
                prevView.removeFromSuperview()
            }
        }

        // If this hosted view was previously bound to a different anchor, clear that mapping.
        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI
        )

        if hostedView.superview !== hostView {
            hostedView.removeFromSuperview()
            hostedView.translatesAutoresizingMaskIntoConstraints = true
            hostedView.autoresizingMask = []
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        } else if hostView.subviews.last !== hostedView {
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        }

        synchronize(hostedId: hostedId)
    }

    func detach(hostedView: NSView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
        if let anchor = entry.anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
        if entry.hostedView?.superview === hostView {
            entry.hostedView?.removeFromSuperview()
        }
    }

    func setVisible(hostedView: NSView, visible: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = visible
        entriesByHostedId[hostedId] = entry
        if !visible {
            hostedView.isHidden = true
        } else {
            synchronize(hostedId: hostedId)
        }
    }

    /// Hide a hosted view only if it's still bound to the given anchor. Used
    /// from SwiftUI dismantle so a stale teardown can't blank an editor that
    /// has already been re-bound to a new anchor (e.g. tab dragged to another
    /// pane: makeNSView at the new location runs before dismantle at the old).
    func setVisible(hostedView: NSView, ifBoundTo anchor: NSView, visible: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let entry = entriesByHostedId[hostedId] else { return }
        guard entry.anchorView === anchor else { return }
        setVisible(hostedView: hostedView, visible: visible)
    }

    func synchronizeForAnchor(_ anchorView: NSView) {
        let anchorId = ObjectIdentifier(anchorView)
        if let hostedId = hostedByAnchorId[anchorId] {
            synchronize(hostedId: hostedId)
        }
    }

    private func synchronizeAll() {
        guard ensureInstalled() else { return }
        for hostedId in Array(entriesByHostedId.keys) {
            synchronize(hostedId: hostedId)
        }
    }

    private func synchronize(hostedId: ObjectIdentifier) {
        guard ensureInstalled() else { return }
        guard let entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView,
              let window,
              anchorView.window === window else {
            hostedView.isHidden = true
            return
        }
        if !entry.visibleInUI {
            hostedView.isHidden = true
            return
        }

        let frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)

        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        guard hasFiniteFrame, frameInHost.width > 1, frameInHost.height > 1 else {
            hostedView.isHidden = true
            return
        }

        if !Self.rectApproximatelyEqual(hostedView.frame, frameInHost) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = frameInHost
            CATransaction.commit()
        }
        hostedView.isHidden = false
    }

    fileprivate func tearDown() {
        removeGeometryObservers()
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        for entry in entriesByHostedId.values {
            entry.hostedView?.removeFromSuperview()
        }
        entriesByHostedId.removeAll()
        hostedByAnchorId.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }
}

@MainActor
enum CasperEditorPortalRegistry {
    private static var portalsByWindowId: [ObjectIdentifier: CasperEditorPortal] = [:]
    private static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]

    private static func portal(for window: NSWindow) -> CasperEditorPortal {
        if let existing = objc_getAssociatedObject(window, &casperEditorPortalKey) as? CasperEditorPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installCloseObserverIfNeeded(for: window)
            return existing
        }
        let portal = CasperEditorPortal(window: window)
        objc_setAssociatedObject(window, &casperEditorPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installCloseObserverIfNeeded(for: window)
        return portal
    }

    private static func installCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &casperEditorPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &casperEditorPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        hostedToWindowId = hostedToWindowId.filter { $0.value != windowId }
        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &casperEditorPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &casperEditorPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &casperEditorPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    static func bind(hostedView: NSView, to anchorView: NSView, visibleInUI: Bool) {
        guard let window = anchorView.window else { return }
        let windowId = ObjectIdentifier(window)
        let hostedId = ObjectIdentifier(hostedView)

        if let oldWindowId = hostedToWindowId[hostedId], oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detach(hostedView: hostedView)
        }
        let p = portal(for: window)
        p.bind(hostedView: hostedView, to: anchorView, visibleInUI: visibleInUI)
        hostedToWindowId[hostedId] = windowId
    }

    static func detach(hostedView: NSView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId.removeValue(forKey: hostedId) else { return }
        portalsByWindowId[windowId]?.detach(hostedView: hostedView)
    }

    static func setVisible(hostedView: NSView, visible: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.setVisible(hostedView: hostedView, visible: visible)
    }

    /// Hide a hosted view only if it's still bound to the given anchor in some
    /// window. Searches across windows because the new bind may have moved the
    /// hosted view before the stale dismantle fires.
    static func setVisible(hostedView: NSView, ifBoundTo anchor: NSView, visible: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.setVisible(hostedView: hostedView, ifBoundTo: anchor, visible: visible)
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        portalsByWindowId[ObjectIdentifier(window)]?.synchronizeForAnchor(anchorView)
    }
}

/// SwiftUI anchor view: an empty placeholder whose geometry drives the portal.
/// The actual editor view lives in the portal above SwiftUI, not as a subview
/// of this anchor.
final class CasperEditorAnchorView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?

    override var isOpaque: Bool { false }

    private struct GeometryState: Equatable {
        let frame: CGRect
        let bounds: CGRect
        let windowNumber: Int?
        let superviewID: ObjectIdentifier?
    }

    private var lastGeometryState: GeometryState?

    private func currentGeometryState() -> GeometryState {
        GeometryState(
            frame: frame,
            bounds: bounds,
            windowNumber: window?.windowNumber,
            superviewID: superview.map(ObjectIdentifier.init)
        )
    }

    private func notifyGeometryChangedIfNeeded() {
        let state = currentGeometryState()
        guard state != lastGeometryState else { return }
        lastGeometryState = state
        onGeometryChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
        notifyGeometryChangedIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notifyGeometryChangedIfNeeded()
    }

    override func layout() {
        super.layout()
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyGeometryChangedIfNeeded()
    }

    // Anchor is purely a geometry stand-in; never intercept events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
