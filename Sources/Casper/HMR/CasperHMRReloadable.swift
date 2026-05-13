// CASPER: Observer protocol for AppKit views that want to react to a
// .casperHMRReloaded notification (Req 8). Constrained to NSObject so the
// default register()/deregister() implementations can use
// objc_setAssociatedObject for token storage without requiring conformers to
// carry an explicit @ivar. Intentionally has NO default casperHMRReload()
// body — a needsDisplay = true default would be misleading correctness (it
// doesn't reload table data, rebind delegates, rebuild closures, refresh
// menus). Each conformer must implement reload semantics for its own view.

#if DEBUG

import AppKit
import ObjectiveC

extension Notification.Name {
    /// Posted by `CasperHMRDaemon` after a successful (or ok_unverified) dylib
    /// swap. userInfo carries "path" (saved file path), "result" (raw string
    /// from the swap event), and "matched_symbols" ([String]).
    static let casperHMRReloaded = Notification.Name("casperHMRReloaded")
}

@MainActor
protocol CasperHMRReloadable: AnyObject where Self: NSObject {
    /// Per-view reload implementation. No default body; every conformer must
    /// implement this. Typical implementations:
    ///   - NSOutlineView/NSTableView host → reloadData() + needsDisplay = true
    ///   - Custom portal owning a STTextView → controller's updateFromConfig()
    ///     + setNeedsLayout = true
    ///   - View with cached delegate references → re-assign delegate
    func casperHMRReload()
}

private nonisolated(unsafe) var casperHMRTokenAssocKey: UInt8 = 0

extension CasperHMRReloadable {
    /// Idempotent — calling register() twice removes the previous token before
    /// installing a new one.
    func register() {
        if let existing = objc_getAssociatedObject(self, &casperHMRTokenAssocKey) as? NSObjectProtocol {
            NotificationCenter.default.removeObserver(existing)
        }
        let token = NotificationCenter.default.addObserver(
            forName: .casperHMRReloaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.casperHMRReload()
            }
        }
        objc_setAssociatedObject(
            self,
            &casperHMRTokenAssocKey,
            token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func deregister() {
        if let existing = objc_getAssociatedObject(self, &casperHMRTokenAssocKey) as? NSObjectProtocol {
            NotificationCenter.default.removeObserver(existing)
            objc_setAssociatedObject(self, &casperHMRTokenAssocKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

#endif
