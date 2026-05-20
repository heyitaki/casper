// CASPER: compact one-line sidebar row (title + relative-time activity).
// Delete if upstream replaces the rich workspace row with a compact layout.

import Foundation
import SwiftUI

enum CasperRelativeTime {
    /// Short relative-age string like "<1m", "42m", "2h", "1d", "34w", "9y".
    /// Sub-minute ages collapse to "<1m" so the sidebar doesn't flicker every
    /// second on freshly-active workspaces. Past-only: future dates render as
    /// "<1m".
    static func shortString(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }
        let years = days / 365
        return "\(years)y"
    }
}

enum CasperWorkspaceTitle {
    /// Activity glyphs Claude Code (and similar agents) prefix the OSC title
    /// with while running. Stripped from display so the sidebar title doesn't
    /// flicker between glyph/no-glyph as the agent works.
    static let activityGlyphs: Set<Character> = [
        "*", "✱", "✲", "✳", "✴", "✵", "✶", "✷", "✸", "✹",
        "✻", "✼", "✽", "✦", "✧", "★", "☆", "✺", "❇", "•",
    ]

    /// Strips a single leading agent activity glyph plus the whitespace that
    /// follows. Acts on display only — the underlying `tab.title` is unchanged
    /// so other surfaces (window title, accessibility, etc.) keep the raw value.
    static func displayTitle(_ raw: String) -> String {
        guard let first = raw.first, activityGlyphs.contains(first) else { return raw }
        let dropped = raw.dropFirst().drop(while: { $0.isWhitespace })
        return String(dropped)
    }
}

/// Case-insensitive substring filter over the title shown in the sidebar
/// (activity glyph stripped, custom title if set). Used by the workspace
/// search bar.
@MainActor
enum CasperWorkspaceTitleFilter {
    static func filter(_ workspaces: [Workspace], query: String) -> [Workspace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return workspaces }
        let needle = trimmed.lowercased()
        return workspaces.filter { workspace in
            let haystack = CasperWorkspaceTitle.displayTitle(workspace.title).lowercased()
            return haystack.contains(needle)
        }
    }
}

/// Trailing accessory for the Casper compact sidebar row. Renders one of:
/// - working    : blue animated ellipsis
/// - needsInput : blue relative-time text
/// - done       : secondary-colored relative-time text
/// - none       : nothing (zero-size)
///
/// Polled every 30s by `TimelineView` so the relative-time text stays fresh
/// without subscribing to `Workspace.objectWillChange` from inside a row body
/// (which would violate the workspace-list snapshot-boundary rule). 30s is
/// enough granularity for the "5m"/"2h" text — finer ticks would just wake
/// SwiftUI to recompute identical strings.
struct CasperWorkspaceActivityIndicator: View {
    let activityProvider: () -> CasperWorkspaceActivity
    let workingFont: Font
    let timeFont: Font
    /// Color used for the relative-time text in `.done` state. `.needsInput`
    /// renders blue unless `selectedColor` is non-nil.
    let doneColor: Color
    /// When non-nil, overrides both `.done` and `.needsInput` text colors —
    /// used so the time text picks up the selected-row foreground (white on
    /// the blue selection chip) instead of the unreadable blue-on-blue.
    let selectedColor: Color?

    /// Shared anchor for the 30-second tick across every row. Without this,
    /// each row's `.periodic(from: .now, by: 30)` starts its clock at row
    /// mount time, so 30 unsynchronized clocks fire ~1 tick/sec into main —
    /// each one a separate SwiftUI layout pass. Anchoring to one type-load
    /// timestamp aligns every row's ticks to the same wall-clock moments
    /// (load + N×30s), letting SwiftUI batch them into a single layout pass
    /// every 30s regardless of how many rows are visible.
    private static let timelineEpoch: Date = Date()

    var body: some View {
        TimelineView(.periodic(from: Self.timelineEpoch, by: 30)) { context in
            let activity = activityProvider()
            switch activity.state {
            case .working:
                Image(systemName: "ellipsis")
                    .font(workingFont)
                    .foregroundColor(.blue)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .lineLimit(1)
            case .needsInput, .done:
                if let date = activity.lastActivityAt {
                    Text(CasperRelativeTime.shortString(since: date, now: context.date))
                        .font(timeFont)
                        .foregroundColor(textColor(for: activity.state))
                        .lineLimit(1)
                        .monospacedDigit()
                }
            case .none:
                EmptyView()
            }
        }
    }

    private func textColor(for state: CasperWorkspaceActivityState) -> Color {
        if let selectedColor { return selectedColor }
        return state == .needsInput ? .blue : doneColor
    }
}
