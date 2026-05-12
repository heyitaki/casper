// CASPER: In minimal mode, set isMovable=false so AppKit doesn't auto-drag the window from the tab strip; explicit drag paths bracket performDrag with isMovable=true.

import AppKit

enum CasperMinimalModeWindowMovable {
    static func apply(to window: NSWindow) {
        guard isMainWorkspaceWindow(window) else { return }
        let desiredMovable = !WorkspacePresentationModeSettings.isMinimal()
        if window.isMovable != desiredMovable {
            window.isMovable = desiredMovable
        }
    }
}
