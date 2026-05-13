// CASPER: VS Code-style preview slicing for the grouped Find sidebar. Adds a leading ellipsis when the first match sits past `leadingBudget` chars, and exposes all match ranges so the row view can highlight every occurrence of the query.

import Foundation

struct CasperFindPreviewSlice: Equatable {
    let text: String
    /// Ranges (UTF-16 units, NSString-compatible) in `text` where the query
    /// occurs. Empty when the query is empty or has no occurrences in the
    /// preview.
    let matchRanges: [NSRange]
    let leadingEllipsis: Bool
}

enum CasperFindPreviewSlicer {
    /// How many UTF-16 units of leading context we try to keep before the
    /// first match before falling back to a leading ellipsis. Tuned so a
    /// typical Find-sidebar width can render meaningful leading context
    /// (function name + scope) rather than just a few chars before the match.
    static let defaultLeadingBudget = 40

    static func slice(
        preview: String,
        query: String,
        leadingBudget: Int = defaultLeadingBudget
    ) -> CasperFindPreviewSlice {
        let nsPreview = preview as NSString
        let nsQuery = query as NSString
        guard nsQuery.length > 0, nsPreview.length > 0 else {
            return CasperFindPreviewSlice(text: preview, matchRanges: [], leadingEllipsis: false)
        }

        let firstMatch = nsPreview.range(
            of: query,
            options: [.caseInsensitive],
            range: NSRange(location: 0, length: nsPreview.length)
        )
        guard firstMatch.location != NSNotFound else {
            return CasperFindPreviewSlice(text: preview, matchRanges: [], leadingEllipsis: false)
        }

        let needsLeadingEllipsis = firstMatch.location > leadingBudget
        let sliceStart = needsLeadingEllipsis ? firstMatch.location - leadingBudget : 0
        let suffix = nsPreview.substring(from: sliceStart)
        let text = needsLeadingEllipsis ? "\u{2026}" + suffix : suffix

        let nsText = text as NSString
        var matches: [NSRange] = []
        var cursor = 0
        while cursor < nsText.length {
            let remaining = NSRange(location: cursor, length: nsText.length - cursor)
            let found = nsText.range(of: query, options: [.caseInsensitive], range: remaining)
            if found.location == NSNotFound { break }
            matches.append(found)
            cursor = found.location + max(found.length, 1)
        }

        return CasperFindPreviewSlice(text: text, matchRanges: matches, leadingEllipsis: needsLeadingEllipsis)
    }
}
