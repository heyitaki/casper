// CASPER: workspaces sidebar search field. Mirrors the AppKit NSSearchField
// styling used in the right-sidebar Find tab so the two surfaces feel
// consistent. Delete if upstream adds a workspace search bar.

import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSSearchField` with the same visual setup as the
/// Find tab's search field (12pt font, no focus ring, single-line). Returns
/// text changes through a `@Binding`. Escape clears the field and resigns
/// first responder.
struct CasperSidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byClipping
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldDidChange(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }

    static func dismantleNSView(_ nsView: NSSearchField, coordinator: Coordinator) {
        nsView.delegate = nil
        nsView.target = nil
        nsView.action = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func searchFieldDidChange(_ sender: NSSearchField) {
            let value = sender.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !control.stringValue.isEmpty {
                    control.stringValue = ""
                    text.wrappedValue = ""
                }
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
