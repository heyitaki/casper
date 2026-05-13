// CASPER: Hosts the TextViewController via the editor portal so the AppKit
// view survives SwiftUI re-mounts (pane drag, workspace switch). The SwiftUI
// representable just provides an anchor whose geometry drives the portal.
// Delete if upstream adds an editor portal layer.

import AppKit
import Combine
import SwiftUI
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
private func casperHighlightProviders(for language: CodeLanguage) -> [HighlightProviding] {
    if language.id == .markdown {
        return [CasperMarkdownHighlightProvider()]
    }
    return [TreeSitterClient()]
}

extension FilePreviewPanel {
    var casperAttachment: CasperEditorAttachment? {
        casperEditorAttachment as? CasperEditorAttachment
    }
}

struct CasperPersistentSourceEditor: NSViewRepresentable {
    let panel: FilePreviewPanel
    let language: CodeLanguage
    let configuration: SourceEditorConfiguration
    let isVisibleInUI: Bool

    final class Coordinator {
        weak var anchor: CasperEditorAnchorView?
        weak var hostedView: NSView?
        var lastVisibleInUI: Bool = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let attachment = CasperEditorAttachment.ensure(
            for: panel,
            language: language,
            configuration: configuration
        )
        let anchor = CasperEditorAnchorView(frame: .zero)
        anchor.wantsLayer = false
        anchor.setAccessibilityElement(false)

        let coordinator = context.coordinator
        coordinator.anchor = anchor
        coordinator.hostedView = attachment.controller.view
        coordinator.lastVisibleInUI = isVisibleInUI

        let hostedView = attachment.controller.view

        anchor.onDidMoveToWindow = { [weak anchor, weak hostedView, weak coordinator] in
            guard let anchor, let hostedView, let coordinator else { return }
            guard anchor.window != nil else {
                CasperEditorPortalRegistry.setVisible(hostedView: hostedView, visible: false)
                return
            }
            CasperEditorPortalRegistry.bind(
                hostedView: hostedView,
                to: anchor,
                visibleInUI: coordinator.lastVisibleInUI
            )
        }
        anchor.onGeometryChanged = { [weak anchor] in
            guard let anchor else { return }
            CasperEditorPortalRegistry.synchronizeForAnchor(anchor)
        }

        if anchor.window != nil {
            CasperEditorPortalRegistry.bind(
                hostedView: hostedView,
                to: anchor,
                visibleInUI: isVisibleInUI
            )
        }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let anchor = nsView as? CasperEditorAnchorView else { return }
        guard let attachment = panel.casperAttachment else { return }
        attachment.apply(language: language, configuration: configuration)
        attachment.syncTextFromPanelIfNeeded()

        let hostedView = attachment.controller.view
        let coordinator = context.coordinator
        coordinator.hostedView = hostedView
        coordinator.lastVisibleInUI = isVisibleInUI

        if anchor.window != nil {
            CasperEditorPortalRegistry.bind(
                hostedView: hostedView,
                to: anchor,
                visibleInUI: isVisibleInUI
            )
        } else {
            CasperEditorPortalRegistry.setVisible(hostedView: hostedView, visible: false)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Hide the portal entry while the SwiftUI placeholder is gone. Use the
        // anchored variant: during a tab drag from pane A to B, SwiftUI runs
        // makeNSView at the new location BEFORE dismantleNSView at the old.
        // An unconditional setVisible(false) would then hide the just-re-bound
        // editor. We only hide if the portal still maps this hosted view to
        // *our* (now-stale) anchor. The hosted editor view stays bound to the
        // portal so the next mount can re-bind it instantly.
        if let hostedView = coordinator.hostedView, let anchor = coordinator.anchor {
            CasperEditorPortalRegistry.setVisible(
                hostedView: hostedView,
                ifBoundTo: anchor,
                visible: false
            )
        }
        if let anchor = coordinator.anchor {
            anchor.onDidMoveToWindow = nil
            anchor.onGeometryChanged = nil
        }
        coordinator.anchor = nil
    }
}

/// Owns the long-lived `TextViewController` for a single `FilePreviewPanel`.
///
/// Held by the panel via `panel.casperEditorAttachment`. Survives workspace
/// remounts so syntax highlight state is preserved. The controller's view
/// lives in `CasperEditorPortal` above SwiftUI, not in the SwiftUI tree.
final class CasperEditorAttachment {
    let controller: TextViewController

    private weak var panel: FilePreviewPanel?
    private var textChangeObserver: NSObjectProtocol?
    private var saveKeyMonitor: Any?
    // CASPER: Combine subscription used by the grouped Find sidebar to navigate
    // to a specific line/column when the user double-clicks a match. Delete if
    // upstream adds line-aware file-preview navigation.
    private var scrollTargetCancellable: AnyCancellable?

    @MainActor
    static func ensure(
        for panel: FilePreviewPanel,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration
    ) -> CasperEditorAttachment {
        if let existing = panel.casperAttachment {
            existing.apply(language: language, configuration: configuration)
            existing.syncTextFromPanelIfNeeded()
            return existing
        }
        let attachment = CasperEditorAttachment(
            panel: panel,
            language: language,
            configuration: configuration
        )
        panel.casperEditorAttachment = attachment
        return attachment
    }

    @MainActor
    private init(
        panel: FilePreviewPanel,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration
    ) {
        self.panel = panel
        self.controller = TextViewController(
            string: "",
            language: language,
            configuration: configuration,
            cursorPositions: [],
            highlightProviders: casperHighlightProviders(for: language)
        )
        // Force `loadView()` now (NSViewController runs it lazily on first
        // `.view` access). That wires `gutterView`, `minimapView`, and the
        // initial highlighter against the empty text storage created in the
        // controller's `init`. We need it eagerly because we cache the
        // controller outside SwiftUI's lifecycle.
        _ = controller.view
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = []
        // Apply the panel's text via the controller (not the bare textView).
        // `controller.setText` replaces the storage AND re-runs
        // `setUpHighlighter`, which rebinds the highlighter to the new
        // storage. Using `textView.setText` here would orphan the highlighter
        // on the old (empty) storage, leaving the editor unhighlighted on
        // first show until the next workspace remount triggered a re-sync.
        controller.setText(panel.textContent)
        observeTextChanges()
        installSaveShortcutMonitor()
        registerFocus()
        observeScrollTargetChanges()
    }

    deinit {
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }
        if let saveKeyMonitor {
            NSEvent.removeMonitor(saveKeyMonitor)
        }
        // Detach from the portal on the main actor; deinit may run off it.
        let view = controller.view
        DispatchQueue.main.async {
            CasperEditorPortalRegistry.detach(hostedView: view)
        }
    }

    @MainActor
    func apply(language: CodeLanguage, configuration: SourceEditorConfiguration) {
        if controller.language.id != language.id {
            controller.language = language
        }
        if controller.configuration != configuration {
            controller.configuration = configuration
        }
        registerFocus()
    }

    @MainActor
    func syncTextFromPanelIfNeeded() {
        guard let panel else { return }
        let panelText = panel.textContent
        // Cheap length-gate before the O(N) string compare. `controller.text`
        // materializes the entire NSTextStorage into a fresh Swift String;
        // for a 16 MB file that's a 16 MB alloc + compare on every SwiftUI
        // re-render. Both lengths are UTF-16 code units, so they're directly
        // comparable; `utf16.count` avoids the NSString bridge alloc.
        let panelLength = panelText.utf16.count
        let storageLength = controller.textView?.textStorage?.length ?? 0
        if panelLength == storageLength, controller.text == panelText {
            return
        }
        // `controller.setText` rebuilds the highlighter; it doesn't go
        // through `replaceCharacters`, so it doesn't post
        // `TextView.textDidChangeNotification` — no re-entry guard needed.
        controller.setText(panelText)
    }

    private func observeTextChanges() {
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification,
            object: controller.textView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.panel?.updateTextContent(self.controller.text)
            }
        }
    }

    @MainActor
    private func registerFocus() {
        guard let panel else { return }
        let root = controller.view
        let primary: NSView = controller.textView ?? root
        panel.attachPreviewFocus(root: root, primaryResponder: primary, intent: .textEditor)
    }

    @MainActor
    private func observeScrollTargetChanges() {
        guard let panel else { return }
        scrollTargetCancellable = panel.$casperPendingScrollTarget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                guard let target else { return }
                MainActor.assumeIsolated {
                    self?.applyScrollTarget(target)
                }
            }
    }

    @MainActor
    private func applyScrollTarget(_ target: CasperFilePreviewScrollTarget) {
        // Make sure the controller is in sync with the panel's current text
        // before resolving the line/column — otherwise we'd scroll to a line
        // that may not exist yet in the controller's storage.
        syncTextFromPanelIfNeeded()
        controller.setCursorPositions(
            [CursorPosition(line: target.line, column: target.column)],
            scrollToVisible: true
        )
        panel?.casperPendingScrollTarget = nil
    }

    private func installSaveShortcutMonitor() {
        guard saveKeyMonitor == nil else { return }
        saveKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let controller = self.controller
            guard let window = controller.view.window, event.window === window else { return event }
            guard let firstResponder = window.firstResponder as? NSView,
                  firstResponder.isDescendant(of: controller.view) else { return event }
            let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
            guard !shortcut.hasChord, shortcut.matches(event: event) else { return event }
            MainActor.assumeIsolated {
                _ = self.panel?.saveTextContent()
            }
            return nil
        }
    }
}
