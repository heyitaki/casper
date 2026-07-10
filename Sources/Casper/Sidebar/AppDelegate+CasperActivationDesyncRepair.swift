// CASPER: AppKit-vs-system activation desync repair; hooked from cmux_sendEvent
// on leftMouseDown. Delete if upstream resyncs NSApp.isActive after a missed
// didBecomeActive (or removes the #3856 first-mouse gate this desync starves).

import AppKit

/// Decision for the activation-desync repair, kept pure for unit testing
/// (mirrors `FirstMouseGatePolicy`).
///
/// Field evidence (dead-sidebar forensics, /tmp/cmux-debug-casper.log): the OS
/// kept routing keyboard events to the app (arrow keys consumed by
/// `FileExplorerNSOutlineView`) while `NSApp.isActive` was stuck `false` and
/// `NSApp.keyWindow` was nil. In that state AppKit treats every sidebar click
/// as an app-activation click and asks the system to activate — which no-ops
/// because the system already considers us active — so no
/// didBecomeActive/didBecomeKey ever fires, and the #3856 first-mouse gate
/// (`FirstMouseGatePolicy`) swallows every click until the user forces a real
/// deactivate→activate cycle (Space switch / Cmd-Tab away and back).
enum CasperActivationDesyncRepairPolicy {
    struct Decision: Equatable {
        var requestActivation: Bool
        var restoreKeyWindow: Bool
    }

    /// System-side activation truth from LaunchServices, independent of
    /// AppKit's (possibly stale) `NSApp.isActive` state machine.
    static var isSystemActive: Bool {
        NSRunningApplication.current.isActive
    }

    /// Precondition (owned by the caller's cheap guards): AppKit believes the
    /// app is inactive, and the click landed on a main workspace window.
    static func decide(systemActive: Bool, windowIsKey: Bool) -> Decision {
        // systemActive while AppKit thinks we're inactive is the desync: restore
        // key/main directly so this click (and the gate's predicate) sees a key
        // window again. When the system agrees we're inactive — a genuine
        // background click — only nudge activation; AppKit's first-mouse
        // semantics (#3856 gate swallow) stay in charge of the click itself.
        Decision(
            requestActivation: true,
            restoreKeyWindow: systemActive && !windowIsKey
        )
    }
}

extension AppDelegate {
    /// Runs before normal mouseDown dispatch in the `cmux_sendEvent` swizzle.
    /// Cheap early-outs keep this off the hot path: it does nothing unless
    /// AppKit already believes the app is inactive.
    func casperRepairActivationDesyncForMouseDown(window: NSWindow, event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        guard !NSApp.isActive else { return }
        guard isMainWorkspaceWindow(window) else { return }
        let systemActive = CasperActivationDesyncRepairPolicy.isSystemActive
        let decision = CasperActivationDesyncRepairPolicy.decide(
            systemActive: systemActive,
            windowIsKey: window.isKeyWindow
        )
#if DEBUG
        cmuxDebugLog(
            "activation.desync.repair systemActive=\(systemActive ? 1 : 0) " +
            "key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0) " +
            "activate=\(decision.requestActivation ? 1 : 0) " +
            "restoreKey=\(decision.restoreKeyWindow ? 1 : 0)"
        )
#endif
        if decision.requestActivation {
            NSApp.activate(ignoringOtherApps: true)
        }
        if decision.restoreKeyWindow {
            window.makeMain()
            window.makeKey()
        }
    }
}
