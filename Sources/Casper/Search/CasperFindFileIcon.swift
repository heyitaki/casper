// CASPER: System icon resolution for the grouped Find sidebar header. Mirrors the Finder-style behaviour used by FileExplorerCellView so a `.swift` row in a search result lines up with the same row in the file tree.

import AppKit
import UniformTypeIdentifiers

enum CasperFindFileIcon {
    /// Returns the system icon for a search-result row. Prefers
    /// `NSWorkspace.icon(forFile:)` (matches Finder exactly) when the file
    /// exists on disk, and falls back to a per-extension type icon so we still
    /// get the right glyph for results streamed in before the underlying file
    /// is reachable (e.g. remote/cached paths).
    static func icon(forAbsolutePath absolutePath: String, relativePath: String) -> NSImage {
        if !absolutePath.isEmpty, FileManager.default.fileExists(atPath: absolutePath) {
            return NSWorkspace.shared.icon(forFile: absolutePath)
        }
        let ext = (relativePath as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .plainText)
    }
}
