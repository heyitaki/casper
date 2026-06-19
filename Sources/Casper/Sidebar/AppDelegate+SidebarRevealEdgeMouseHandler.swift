// CASPER: Reveal-strip edge mouse-down handlers; hooked from cmux_sendEvent BEFORE AppKit's edge-resize tracking starts.

import AppKit

extension AppDelegate {
    @discardableResult
    func handleSidebarRevealLeadingEdgeMouseDown(window: NSWindow, event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        // Shift+click must reach the terminal surface for text selection —
        // see SidebarRevealStripMetrics.shouldBypassRevealIntercept.
        guard !SidebarRevealStripMetrics.shouldBypassRevealIntercept(modifierFlags: event.modifierFlags) else {
            return false
        }
        let location = event.locationInWindow
        guard location.x >= 0, location.x < SidebarRevealStripMetrics.width else {
            return false
        }
        guard isMainWorkspaceWindow(window) else { return false }
        guard let context = mainWindowContexts.values.first(where: { $0.window === window }),
              !context.sidebarState.isVisible else {
            return false
        }
        return runSidebarRevealEdgeMouseDownLoop(
            window: window,
            edge: .leading,
            toggle: { context.sidebarState.toggle() }
        )
    }

    @discardableResult
    func handleSidebarRevealTrailingEdgeMouseDown(window: NSWindow, event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        guard !SidebarRevealStripMetrics.shouldBypassRevealIntercept(modifierFlags: event.modifierFlags) else {
            return false
        }
        let location = event.locationInWindow
        let trailingX = window.frame.width
        guard location.x > trailingX - SidebarRevealStripMetrics.width,
              location.x <= trailingX else {
            return false
        }
        guard isMainWorkspaceWindow(window) else { return false }
        guard let context = mainWindowContexts.values.first(where: { $0.window === window }),
              let fileExplorerState = context.fileExplorerState,
              !fileExplorerState.isVisible else {
            return false
        }
        return runSidebarRevealEdgeMouseDownLoop(
            window: window,
            edge: .trailing,
            toggle: { fileExplorerState.toggle() }
        )
    }

    @discardableResult
    fileprivate func runSidebarRevealEdgeMouseDownLoop(
        window: NSWindow,
        edge: SidebarResizeInteraction.Edge,
        toggle: () -> Void
    ) -> Bool {
        let startScreenLocation = NSEvent.mouseLocation
        let startFrame = window.frame
        let threshold = SidebarRevealStripMetrics.tapThreshold
        let minWidth = max(window.minSize.width, CGFloat(SessionPersistencePolicy.minimumWindowWidth))
        let maxWidth = window.maxSize.width.isFinite ? window.maxSize.width : .greatestFiniteMagnitude
        let isFullScreen = window.styleMask.contains(.fullScreen)
        var didStartResize = false
        defer {
            if didStartResize {
                NSCursor.arrow.set()
            }
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let next = window.nextEvent(matching: mask) {
            let current = NSEvent.mouseLocation
            let dx = current.x - startScreenLocation.x
            let dy = current.y - startScreenLocation.y
            let movement = max(abs(dx), abs(dy))

            switch next.type {
            case .leftMouseDragged:
                // Fullscreen windows can't be edge-resized, so don't show the
                // resize cursor or attempt setFrame — the system would ignore it.
                guard !isFullScreen else { break }
                if didStartResize || movement >= threshold {
                    didStartResize = true
                    NSCursor.resizeLeftRight.set()
                    let newFrame = SidebarRevealEdgeGeometry.resizedFrame(
                        startFrame: startFrame,
                        dxScreen: dx,
                        minWidth: minWidth,
                        maxWidth: maxWidth,
                        draggedEdge: edge
                    )
                    if newFrame != window.frame {
                        window.setFrame(newFrame, display: true, animate: false)
                    }
                }
            case .leftMouseUp:
                if !didStartResize && movement < threshold {
                    toggle()
                }
                return true
            default:
                break
            }
        }
        return true
    }
}
