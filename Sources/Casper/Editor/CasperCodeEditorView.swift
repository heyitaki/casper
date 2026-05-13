// CASPER: SwiftUI wrapper for FilePreviewPanel text branch. Delete if upstream
// adds an editor portal layer like TerminalWindowPortal.

import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

enum CasperEditorPreferences {
    static let wrapLinesKey = "casper.editor.wrapLines"
    static let defaultWrapLines = false
}

struct CasperCodeEditorView: View {
    @ObservedObject var panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor

    @AppStorage(CasperEditorPreferences.wrapLinesKey)
    private var wrapLines = CasperEditorPreferences.defaultWrapLines

    var body: some View {
        CasperPersistentSourceEditor(
            panel: panel,
            language: detectLanguage(),
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: editorTheme(),
                    font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    wrapLines: wrapLines
                ),
                peripherals: .init(showMinimap: false)
            ),
            isVisibleInUI: isVisibleInUI
        )
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

struct CasperWrapLinesToggleButton: View {
    @AppStorage(CasperEditorPreferences.wrapLinesKey)
    private var wrapLines = CasperEditorPreferences.defaultWrapLines

    var body: some View {
        Button {
            wrapLines.toggle()
        } label: {
            Image(systemName: wrapLines ? "arrow.turn.down.left" : "arrow.right.to.line")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        wrapLines
            ? String(localized: "filePreview.wrapLines.disable", defaultValue: "Disable line wrapping")
            : String(localized: "filePreview.wrapLines.enable", defaultValue: "Enable line wrapping")
    }
}
