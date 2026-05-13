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

@MainActor
private func applyLayoutRefresh(to controller: TextViewController) {
    guard let textView = controller.textView else { return }
    textView.layoutManager.setNeedsLayout()
    textView.updateFrameIfNeeded()
    textView.needsDisplay = true
    controller.view.needsLayout = true
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
        var bindGeneration: UInt64 = 0
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
            coordinator.bindGeneration &+= 1
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
        applyLayoutRefresh(to: attachment.controller)
        // Re-kick after the portal binds and refreshes layout — at this point
        // the clipView may finally have a real size from cascaded autolayout.
        DispatchQueue.main.async { [weak attachment] in
            attachment?.kickFullDocLayoutIfPending()
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
    private var lastAppliedWrapLines: Bool?
    private var clipViewFrameObserver: NSObjectProtocol?
    private var textViewBoundsObserver: NSObjectProtocol?
    // CASPER: Combine subscription used by the grouped Find sidebar to navigate
    // to a specific line/column when the user double-clicks a match. Delete if
    // upstream adds line-aware file-preview navigation.
    private var scrollTargetCancellable: AnyCancellable?
    // True when the next time the viewport gets a non-zero size we should walk
    // the full document so off-screen long lines contribute to maxLineWidth.
    // Set in apply() when wrap is off and on text change.
    private var pendingFullDocLayout: Bool = false

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
        installFullDocLayoutObservers()
        registerFocus()
        observeScrollTargetChanges()
    }

    deinit {
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }
        if let clipViewFrameObserver {
            NotificationCenter.default.removeObserver(clipViewFrameObserver)
        }
        if let textViewBoundsObserver {
            NotificationCenter.default.removeObserver(textViewBoundsObserver)
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
        // When wrap is OFF, the layout manager only knows the width of lines
        // that have been laid out so far (visible viewport ± padding). Long
        // off-screen lines don't contribute to maxLineWidth, so the textView
        // frame stays narrow and the horizontal scroller has nothing to scroll.
        // Mark the doc as needing a full walk; the clipView frame observer will
        // drain the flag once the viewport has a real size. Run whenever wrap
        // is off and either:
        //   - first apply (lastAppliedWrapLines == nil), or
        //   - just transitioned from wrap-on to wrap-off.
        let newWrap = configuration.appearance.wrapLines
        let previousWrap = lastAppliedWrapLines
        lastAppliedWrapLines = newWrap
        if !newWrap, previousWrap != false {
            pendingFullDocLayout = true
        }
        drainPendingFullDocLayoutIfReady()
        // Belt-and-suspenders: defer one more drain attempt for the case where
        // the clipView frame-change notification has already fired (before the
        // observer was installed for this mount) or otherwise won't fire.
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingFullDocLayoutIfReady()
        }
        registerFocus()
    }

    @MainActor
    func kickFullDocLayoutIfPending() {
        drainPendingFullDocLayoutIfReady()
    }

    @MainActor
    private func installFullDocLayoutObservers() {
        // Watch the scrollView's clipView (viewport) AND the textView's own
        // bounds. Either gets resized when the editor first becomes visible
        // (portal binds geometry → auto layout sizes findViewController.view
        // → scrollView → clipView). On every such size change we attempt to
        // drain pendingFullDocLayout. The drain is cheap: bails out if the
        // flag is clear or wrap is on, and the layout walk itself is O(N)
        // over a line tree, run at most once per text content change.
        let clipView = controller.scrollView.contentView
        clipView.postsFrameChangedNotifications = true
        clipViewFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.drainPendingFullDocLayoutIfReady()
            }
        }
        if let textView = controller.textView {
            textView.postsBoundsChangedNotifications = true
            textViewBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.drainPendingFullDocLayoutIfReady()
                }
            }
        }
    }

    @MainActor
    private func drainPendingFullDocLayoutIfReady() {
        guard pendingFullDocLayout else { return }
        guard !controller.configuration.appearance.wrapLines else {
            pendingFullDocLayout = false
            return
        }
        let clipBounds = controller.scrollView.contentView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else { return }
        pendingFullDocLayout = false
        forceFullDocumentLayout()
    }

    @MainActor
    private func forceFullDocumentLayout() {
        guard let textView = controller.textView,
              let layoutManager = textView.layoutManager else { return }
        // Use a probe height that covers any plausible document. estimatedHeight
        // can be 0 at first mount (before the view is sized), and even when
        // populated it's only the *already-laid-out* extent, not the full doc.
        // 1e9 pt is enough for a billion-line file but small enough to avoid
        // CG flagging it as a near-infinity invalid rect.
        let probeRect = NSRect(
            x: 0,
            y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: 1_000_000_000
        )
        _ = layoutManager.layoutLines(in: probeRect)
        textView.updateFrameIfNeeded()
    }

    @MainActor
    func syncTextFromPanelIfNeeded() {
        guard let panel else { return }
        let panelText = panel.textContent
        guard controller.text != panelText else { return }
        // `controller.setText` rebuilds the highlighter; it doesn't go
        // through `replaceCharacters`, so it doesn't post
        // `TextView.textDidChangeNotification` — no re-entry guard needed.
        controller.setText(panelText)
        if !controller.configuration.appearance.wrapLines {
            pendingFullDocLayout = true
            drainPendingFullDocLayoutIfReady()
        }
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
