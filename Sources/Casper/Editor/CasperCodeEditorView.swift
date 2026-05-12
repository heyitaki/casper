// CASPER: SwiftUI wrapper around CodeEditSourceEditor's SourceEditor for the FilePreviewPanel text branch (gated by CasperEditorConfig).

import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

struct CasperCodeEditorView: View {
    @ObservedObject var panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor

    @State private var text: String = ""
    @State private var editorState = SourceEditorState()
    @StateObject private var coordinatorBox = CasperEditorCoordinatorBox()

    var body: some View {
        SourceEditor(
            $text,
            language: detectLanguage(),
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: editorTheme(),
                    font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    wrapLines: true
                )
            ),
            state: $editorState,
            coordinators: coordinatorBox.coordinatorsArray(panel: panel)
        )
        .opacity(isVisibleInUI ? 1 : 0)
        .onAppear {
            coordinatorBox.syncTextFromPanel(panel)
        }
        .onChange(of: panel.textContent) { _, _ in
            coordinatorBox.syncTextFromPanel(panel)
        }
        .onChange(of: panel.filePath) { _, _ in
            coordinatorBox.syncTextFromPanel(panel)
        }
        .onChange(of: text) { _, newValue in
            panel.updateTextContent(newValue)
        }
    }

    private func detectLanguage() -> CodeLanguage {
        CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: panel.filePath))
    }

    private func editorTheme() -> EditorTheme {
        let fg = themeForegroundColor
        let bg = themeBackgroundColor
        return EditorTheme(
            text: .init(color: fg),
            insertionPoint: fg,
            invisibles: .init(color: fg.withAlphaComponent(0.3)),
            background: bg,
            lineHighlight: fg.withAlphaComponent(0.06),
            selection: fg.withAlphaComponent(0.20),
            keywords: .init(color: NSColor(red: 1.00, green: 0.48, blue: 0.70, alpha: 1.0), bold: true),
            commands: .init(color: NSColor(red: 0.47, green: 0.76, blue: 0.70, alpha: 1.0)),
            types: .init(color: NSColor(red: 0.42, green: 0.87, blue: 1.00, alpha: 1.0)),
            attributes: .init(color: NSColor(red: 0.80, green: 0.59, blue: 0.41, alpha: 1.0)),
            variables: .init(color: NSColor(red: 0.31, green: 0.69, blue: 0.80, alpha: 1.0)),
            values: .init(color: NSColor(red: 0.70, green: 0.51, blue: 0.92, alpha: 1.0)),
            numbers: .init(color: NSColor(red: 0.85, green: 0.79, blue: 0.49, alpha: 1.0)),
            strings: .init(color: NSColor(red: 1.00, green: 0.51, blue: 0.44, alpha: 1.0)),
            characters: .init(color: NSColor(red: 0.85, green: 0.79, blue: 0.49, alpha: 1.0)),
            comments: .init(color: fg.withAlphaComponent(0.5))
        )
    }
}

/// Holds a single coordinator instance across SwiftUI re-evaluations so we don't
/// rebuild the TextViewCoordinator (and its NSEvent monitor) on every render.
private final class CasperEditorCoordinatorBox: ObservableObject {
    private var coordinator: CasperEditorCoordinator?

    func coordinatorsArray(panel: FilePreviewPanel) -> [any TextViewCoordinator] {
        if let coordinator {
            coordinator.update(panel: panel)
            return [coordinator]
        }
        let created = CasperEditorCoordinator(panel: panel)
        coordinator = created
        return [created]
    }

    @MainActor
    func syncTextFromPanel(_ panel: FilePreviewPanel) {
        coordinator?.applyText(panel.textContent)
    }
}

private final class CasperEditorCoordinator: TextViewCoordinator {
    private weak var panel: FilePreviewPanel?
    private weak var controller: TextViewController?
    private var keyMonitor: Any?

    init(panel: FilePreviewPanel) {
        self.panel = panel
    }

    func update(panel: FilePreviewPanel) {
        self.panel = panel
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        // Initial text sync is deferred to .onAppear via applyText(_:);
        // calling controller.text here crashes because gutterView/highlighter
        // are not yet loaded (prepareCoordinator runs inside the controller's init).
        registerFocus()
        installSaveShortcutMonitor()
    }

    func applyText(_ newText: String) {
        guard let controller else { return }
        MainActor.assumeIsolated {
            if controller.text != newText {
                controller.text = newText
            }
        }
    }

    func controllerDidAppear(controller: TextViewController) {
        registerFocus()
    }

    func controllerDidDisappear(controller: TextViewController) {}

    func textViewDidChangeText(controller: TextViewController) {}

    func textViewDidChangeSelection(
        controller: TextViewController,
        newPositions: [CursorPosition]
    ) {}

    func destroy() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        controller = nil
        panel = nil
    }

    private func registerFocus() {
        guard let panel, let controller else { return }
        let root = controller.view
        let primary: NSView = controller.textView ?? root
        MainActor.assumeIsolated {
            panel.attachPreviewFocus(root: root, primaryResponder: primary, intent: .textEditor)
        }
    }

    private func installSaveShortcutMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let controller = self.controller else { return event }
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
