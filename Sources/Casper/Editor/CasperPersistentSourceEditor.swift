// CASPER: Caches TextViewController on FilePreviewPanel so highlight state
// survives workspace remounts. Delete if upstream adds an editor portal layer.

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

struct CasperPersistentSourceEditor: NSViewControllerRepresentable {
    let panel: FilePreviewPanel
    let language: CodeLanguage
    let configuration: SourceEditorConfiguration

    func makeNSViewController(context: Context) -> TextViewController {
        let attachment = CasperEditorAttachment.ensure(
            for: panel,
            language: language,
            configuration: configuration
        )
        return attachment.controller
    }

    func updateNSViewController(_ controller: TextViewController, context: Context) {
        guard let attachment = panel.casperAttachment else { return }
        attachment.apply(language: language, configuration: configuration)
        attachment.syncTextFromPanelIfNeeded()
    }

    static func dismantleNSViewController(_ controller: TextViewController, coordinator: ()) {
        // Panel owns the attachment via `casperEditorAttachment`; cleanup happens in panel.close().
    }
}

/// Owns the long-lived `TextViewController` for a single `FilePreviewPanel`.
///
/// Held by the panel via `panel.casperEditorAttachment`. Survives workspace
/// remounts so syntax highlight state is preserved.
final class CasperEditorAttachment {
    let controller: TextViewController

    private weak var panel: FilePreviewPanel?
    private var textChangeObserver: NSObjectProtocol?
    private var saveKeyMonitor: Any?

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
    }

    deinit {
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }
        if let saveKeyMonitor {
            NSEvent.removeMonitor(saveKeyMonitor)
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
        guard controller.text != panelText else { return }
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
