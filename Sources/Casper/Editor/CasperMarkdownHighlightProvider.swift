// CASPER: HighlightProviding for markdown that maps the nvim-treesitter capture
// names used in CodeEditLanguages' bundled markdown queries onto the closed
// `CaptureName` enum CodeEditSourceEditor recognizes.
//
// Why this exists: CodeEditSourceEditor's default `TreeSitterClient` parses
// markdown and runs the query just fine, but the markdown query uses captures
// like `text.title`, `text.literal`, `text.uri`, `punctuation.special`, etc.
// which aren't in `CaptureName.fromString`, so they get silently dropped
// (see TreeSitterClient+Highlight.swift:105). Result: markdown opens as plain
// text. This provider remaps those names to recognized ones so they pick up
// theme colors.
//
// Scope: block-level only. We also re-parse with the inline parser and merge
// captures so `*italic*`, `**bold**`, and `` `code` `` light up. Both passes
// reuse the same `Parser` instance because reparsing a markdown file is cheap
// compared to setting up tree-sitter from scratch.
//
// Delete if upstream `CaptureName` grows entries for the markdown captures, or
// if CodeEditSourceEditor adds a remapping hook for unrecognized capture names.

import Foundation
import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftTreeSitter

final class CasperMarkdownHighlightProvider: HighlightProviding {
    private weak var textView: TextView?
    private var blockParser: Parser?
    private var inlineParser: Parser?
    private var blockQuery: Query?
    private var inlineQuery: Query?

    @MainActor
    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        self.textView = textView
        blockParser = makeParser(for: CodeLanguage.markdown)
        blockQuery = TreeSitterModel.shared.markdownQuery
        inlineParser = makeParser(for: CodeLanguage.markdownInline)
        inlineQuery = TreeSitterModel.shared.markdownInlineQuery
    }

    private func makeParser(for codeLanguage: CodeLanguage) -> Parser? {
        guard let language = codeLanguage.language else { return nil }
        let parser = Parser()
        try? parser.setLanguage(language)
        return parser
    }

    @MainActor
    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        // Markdown highlights are context-sensitive at the block level
        // (typing `#` at the start of a paragraph promotes it to a heading,
        // adding ``` flips between code-block and prose), so we invalidate
        // the whole document on every edit. Markdown files are small enough
        // that re-parsing the full text is cheap.
        let length = textView.documentRange.length
        let indices = length > 0 ? IndexSet(integersIn: 0..<length) : IndexSet()
        completion(.success(indices))
    }

    @MainActor
    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let text = textView.string
        var collected: [(NSRange, CaptureName, Int)] = []

        if let parser = blockParser, let query = blockQuery, let tree = parser.parse(text) {
            collected.append(contentsOf: captures(in: tree, query: query, source: text, range: range))
        }
        if let parser = inlineParser, let query = inlineQuery, let tree = parser.parse(text) {
            collected.append(contentsOf: captures(in: tree, query: query, source: text, range: range))
        }

        // Dedupe by range, preferring the lower capture index (matches
        // TreeSitterClient's "earlier patterns win" rule).
        var preferred: [NSRange: (CaptureName, Int)] = [:]
        for (captureRange, capture, index) in collected {
            if let existing = preferred[captureRange], existing.1 <= index { continue }
            preferred[captureRange] = (capture, index)
        }

        let highlights = preferred.map { entry in
            HighlightRange(range: entry.key, capture: entry.value.0)
        }
        completion(.success(highlights.sorted { $0.range.location < $1.range.location }))
    }

    private func captures(
        in tree: MutableTree,
        query: Query,
        source: String,
        range: NSRange
    ) -> [(NSRange, CaptureName, Int)] {
        let cursor = query.execute(in: tree)
        cursor.setRange(range)
        var results: [(NSRange, CaptureName, Int)] = []
        for match in cursor.resolve(with: .init(string: source)) {
            for capture in match.captures {
                guard let mapped = Self.mapCapture(name: capture.name) else { continue }
                // `cursor.setRange` only filters by the node's start position;
                // a node that starts before `range` can still bleed into it
                // (and we'd emit a highlight at offsets outside the requested
                // window). Mirror TreeSitterClient+Highlight.swift's
                // `range.intersection(...)` clamp.
                let clipped = capture.range.intersection(range) ?? NSRange(location: 0, length: 0)
                guard clipped.length > 0 else { continue }
                results.append((clipped, mapped, capture.index))
            }
        }
        return results
    }

    private static func mapCapture(name: String?) -> CaptureName? {
        guard let name else { return nil }
        // Try upstream first so overlapping names (comment, string, keyword) keep their canonical color.
        if let upstream = CaptureName.fromString(name) {
            return upstream
        }
        switch name {
        case "text.title", "punctuation.special":
            return .keyword
        case "text.literal", "string.escape":
            return .string
        case "punctuation.delimiter":
            return .comment
        case "text.uri", "text.reference":
            return .variable
        case "text.emphasis", "text.strong":
            // No italic/bold weight available — borrow the type color as a visual cue.
            return .type
        default:
            return nil
        }
    }
}
