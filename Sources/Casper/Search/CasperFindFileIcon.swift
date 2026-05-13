// CASPER: Icon resolution for the grouped Find sidebar header. `symbol(forRelativePath:)`
// returns a flat SF Symbol mapped by extension; the user prefers a clean
// monochrome glyph that lines up with text rather than a Finder-style page
// outline containing a tiny glyph.

import AppKit

enum CasperFindFileIcon {
    /// Returns a tinted SF Symbol that represents the file's type, picked from
    /// its filename / extension. The caller is expected to apply the tint via
    /// `NSImageView.contentTintColor` using `symbolTint(forRelativePath:)`.
    static func symbol(forRelativePath relativePath: String) -> NSImage {
        let name = symbolName(forRelativePath: relativePath)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            ?? NSImage()
        let configured = base.withSymbolConfiguration(config) ?? base
        configured.isTemplate = true
        return configured
    }

    /// Returns a language-specific tint color for the file's icon. Approximates
    /// the color conventions used by VS Code's Material Icon Theme so a quick
    /// scan of the sidebar tells the user what language each result is in,
    /// rather than every file looking like the same grey glyph.
    static func symbolTint(forRelativePath relativePath: String) -> NSColor {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if let color = extensionTints[ext] { return color }
        return .secondaryLabelColor
    }

    private static let extensionTints: [String: NSColor] = [
        // Apple / Swift / C-family
        "swift": .systemOrange,
        "m": .systemTeal,
        "mm": .systemTeal,
        "h": .systemPurple,
        "hpp": .systemPurple,
        "c": .systemBlue,
        "cc": .systemBlue,
        "cpp": .systemBlue,
        "cxx": .systemBlue,
        "plist": .systemGray,
        "xcconfig": .systemGray,
        "entitlements": .systemGray,
        "xcstrings": .systemPink,
        "storyboard": .systemBlue,
        "xib": .systemBlue,
        "pbxproj": .systemGray,

        // JS / TS / web
        "js": .systemYellow,
        "jsx": .systemYellow,
        "mjs": .systemYellow,
        "cjs": .systemYellow,
        "ts": .systemBlue,
        "tsx": .systemBlue,
        "json": .systemYellow,
        "jsonc": .systemYellow,
        "json5": .systemYellow,
        "html": .systemOrange,
        "htm": .systemOrange,
        "css": .systemBlue,
        "scss": .systemPink,
        "sass": .systemPink,
        "less": .systemBlue,
        "vue": .systemGreen,
        "svelte": .systemOrange,

        // Languages
        "py": .systemBlue,
        "rb": .systemRed,
        "rs": .systemOrange,
        "go": .systemCyan,
        "java": .systemRed,
        "kt": .systemPurple,
        "kts": .systemPurple,
        "scala": .systemRed,
        "zig": .systemOrange,
        "lua": .systemBlue,
        "php": .systemPurple,
        "pl": .systemPurple,
        "dart": .systemBlue,
        "ex": .systemPurple,
        "exs": .systemPurple,
        "erl": .systemRed,
        "hs": .systemPurple,
        "clj": .systemGreen,
        "cljs": .systemGreen,
        "ml": .systemOrange,
        "fs": .systemBlue,
        "nim": .systemYellow,

        // Shells
        "sh": .systemGreen,
        "bash": .systemGreen,
        "zsh": .systemGreen,
        "fish": .systemGreen,
        "ps1": .systemBlue,
        "bat": .systemGreen,
        "cmd": .systemGreen,

        // Data / config
        "yaml": .systemRed,
        "yml": .systemRed,
        "toml": .systemBrown,
        "ini": .systemGray,
        "conf": .systemGray,
        "cfg": .systemGray,
        "xml": .systemOrange,
        "csv": .systemGreen,
        "tsv": .systemGreen,
        "sql": .systemPink,

        // Docs
        "md": .systemBlue,
        "markdown": .systemBlue,
        "mdx": .systemBlue,
        "rst": .systemBlue,
        "txt": .secondaryLabelColor,
        "rtf": .secondaryLabelColor,
        "pdf": .systemRed,
        "tex": .systemGreen,

        // Media
        "png": .systemPurple,
        "jpg": .systemPurple,
        "jpeg": .systemPurple,
        "gif": .systemPurple,
        "webp": .systemPurple,
        "bmp": .systemPurple,
        "tiff": .systemPurple,
        "tif": .systemPurple,
        "ico": .systemPurple,
        "svg": .systemOrange,
        "heic": .systemPurple,
        "mp3": .systemPink,
        "wav": .systemPink,
        "flac": .systemPink,
        "ogg": .systemPink,
        "mp4": .systemIndigo,
        "mov": .systemIndigo,
        "m4v": .systemIndigo,
        "avi": .systemIndigo,
        "mkv": .systemIndigo,

        // Archives / binaries
        "zip": .systemBrown,
        "tar": .systemBrown,
        "gz": .systemBrown,
        "tgz": .systemBrown,
        "bz2": .systemBrown,
        "xz": .systemBrown,
        "7z": .systemBrown,
        "rar": .systemBrown,

        // Misc
        "log": .systemGray,
        "lock": .systemGray,
        "diff": .systemGreen,
        "patch": .systemGreen,
    ]

    private static func symbolName(forRelativePath relativePath: String) -> String {
        let lowerName = ((relativePath as NSString).lastPathComponent).lowercased()
        if let exactName = exactNameSymbols[lowerName] { return exactName }

        let ext = (relativePath as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let mapped = extensionSymbols[ext] { return mapped }

        return "doc.text"
    }

    // Filenames whose semantics outrank their extension (e.g. "Dockerfile",
    // "Makefile", lockfiles).
    private static let exactNameSymbols: [String: String] = [
        "dockerfile": "shippingbox",
        "makefile": "hammer",
        "package.json": "shippingbox",
        "package-lock.json": "lock",
        "yarn.lock": "lock",
        "bun.lock": "lock",
        "bun.lockb": "lock",
        "cargo.lock": "lock",
        "podfile": "shippingbox",
        "podfile.lock": "lock",
        "gemfile": "shippingbox",
        "gemfile.lock": "lock",
        ".gitignore": "eye.slash",
        ".gitattributes": "eye.slash",
        ".env": "key",
        "readme.md": "book",
        "license": "scroll",
        "license.md": "scroll",
        "license.txt": "scroll",
    ]

    private static let extensionSymbols: [String: String] = [
        // CASPER: where possible, distinguish each language with its own
        // letter-square SF Symbol so a sidebar of mixed file types has
        // visually distinct rows. curlybraces is reserved for files where
        // we don't have a clearer glyph and the "this is code" signal is
        // the most useful information.

        // Apple / Swift
        "swift": "swift",
        "m": "m.square",
        "mm": "m.square",
        "h": "h.square",
        "hpp": "h.square",
        "c": "c.square",
        "cc": "c.square",
        "cpp": "c.square",
        "cxx": "c.square",
        "plist": "list.bullet.rectangle",
        "xcconfig": "gearshape",
        "entitlements": "lock.shield",
        "xcstrings": "character.bubble",
        "storyboard": "rectangle.3.group",
        "xib": "rectangle.3.group",
        "pbxproj": "hammer",

        // JS / TS / web
        "js": "j.square",
        "jsx": "j.square",
        "mjs": "j.square",
        "cjs": "j.square",
        "ts": "t.square",
        "tsx": "t.square",
        "json": "curlybraces.square",
        "jsonc": "curlybraces.square",
        "json5": "curlybraces.square",
        "html": "chevron.left.forwardslash.chevron.right",
        "htm": "chevron.left.forwardslash.chevron.right",
        "css": "paintbrush",
        "scss": "paintbrush",
        "sass": "paintbrush",
        "less": "paintbrush",
        "vue": "v.square",
        "svelte": "s.square",

        // Systems / scripting — each gets its own letter glyph so a Python
        // file doesn't look identical to a Ruby file in the sidebar.
        "py": "p.square",
        "rb": "r.square",
        "rs": "r.circle",
        "go": "g.square",
        "java": "j.circle",
        "kt": "k.square",
        "kts": "k.square",
        "scala": "s.circle",
        "zig": "z.square",
        "lua": "l.square",
        "php": "p.circle",
        "pl": "p.circle",
        "dart": "d.square",
        "ex": "e.square",
        "exs": "e.square",
        "erl": "e.circle",
        "hs": "h.circle",
        "clj": "c.circle",
        "cljs": "c.circle",
        "ml": "m.circle",
        "fs": "f.square",
        "nim": "n.square",
        "sh": "terminal",
        "bash": "terminal",
        "zsh": "terminal",
        "fish": "terminal",
        "ps1": "terminal",
        "bat": "terminal",
        "cmd": "terminal",

        // Data / config
        "yaml": "list.bullet.rectangle",
        "yml": "list.bullet.rectangle",
        "toml": "list.bullet.rectangle",
        "ini": "list.bullet.rectangle",
        "conf": "list.bullet.rectangle",
        "cfg": "list.bullet.rectangle",
        "xml": "chevron.left.forwardslash.chevron.right",
        "csv": "tablecells",
        "tsv": "tablecells",
        "sql": "cylinder.split.1x2",

        // Docs
        "md": "text.alignleft",
        "markdown": "text.alignleft",
        "mdx": "text.alignleft",
        "rst": "text.alignleft",
        "txt": "doc.text",
        "rtf": "doc.richtext",
        "pdf": "doc.richtext",
        "tex": "function",

        // Images / media
        "png": "photo",
        "jpg": "photo",
        "jpeg": "photo",
        "gif": "photo",
        "webp": "photo",
        "bmp": "photo",
        "tiff": "photo",
        "tif": "photo",
        "ico": "photo",
        "svg": "scribble.variable",
        "heic": "photo",
        "mp3": "music.note",
        "wav": "music.note",
        "flac": "music.note",
        "ogg": "music.note",
        "mp4": "film",
        "mov": "film",
        "m4v": "film",
        "avi": "film",
        "mkv": "film",

        // Archives / binaries
        "zip": "archivebox",
        "tar": "archivebox",
        "gz": "archivebox",
        "tgz": "archivebox",
        "bz2": "archivebox",
        "xz": "archivebox",
        "7z": "archivebox",
        "rar": "archivebox",
        "dmg": "externaldrive",
        "iso": "opticaldiscdrive",
        "exe": "app.badge",
        "app": "app.badge",
        "dll": "shippingbox",
        "so": "shippingbox",
        "dylib": "shippingbox",
        "a": "shippingbox",
        "o": "shippingbox",

        // Fonts
        "ttf": "textformat",
        "otf": "textformat",
        "woff": "textformat",
        "woff2": "textformat",

        // Misc
        "log": "doc.text.magnifyingglass",
        "lock": "lock",
        "diff": "arrow.left.arrow.right",
        "patch": "arrow.left.arrow.right",
    ]
}
