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
/// - working    : blue animated 3-dot ellipsis (one dot lit at a time)
/// - needsInput : blue relative-time text
/// - done       : secondary-colored relative-time text
/// - none       : nothing (zero-size)
///
/// Two `TimelineView` schedules, both anchored to a shared per-type epoch so
/// every row's ticks align to the same wall-clock instants and SwiftUI can
/// batch them into one layout pass:
/// - relative-time text: 30s — granularity for "5m"/"2h".
/// - working dots:       `workingTickInterval` — manual phase animation.
///
/// The working state used to drive `.symbolEffect(.variableColor.iterative,
/// options: .repeating)`, which installs a continuously-running `CAAnimation`
/// per row. With N simultaneously-working workspaces that was N independent
/// continuous render-server animation loops, pressuring CA::Transaction::commit
/// on the main thread and producing the foreground-only freeze (cleared by
/// backgrounding, because macOS pauses CA composition there). The replacement
/// is a discrete TimelineView tick at `workingTickInterval` with no underlying
/// CAAnimation — each row produces one SwiftUI update per tick instead of a
/// continuous animation. The shared epoch is intended to let SwiftUI batch
/// concurrent TimelineViews into a single layout pass per tick.
struct CasperWorkspaceActivityIndicator: View {
    let activityProvider: () -> CasperWorkspaceActivity
    let timeFont: Font
    /// Color used for the relative-time text in `.done` state. `.needsInput`
    /// renders blue unless `selectedColor` is non-nil.
    let doneColor: Color
    /// When non-nil, overrides the `.working` dots color and both `.done`
    /// and `.needsInput` text colors — used so the indicator picks up the
    /// selected-row foreground (white on the blue selection chip) instead of
    /// the unreadable blue-on-blue.
    let selectedColor: Color?

    /// Shared anchor for the 30-second relative-time tick across every row.
    /// Without this, each row's `.periodic(from: .now, by: 30)` starts its
    /// clock at row mount time, so 30 unsynchronized clocks fire ~1 tick/sec
    /// into main. Anchoring to one type-load timestamp aligns every row's
    /// ticks to the same wall-clock moments, letting SwiftUI batch them.
    fileprivate static let timelineEpoch: Date = Date()

    /// Shared anchor + period for the working-state 3-dot animation. Same
    /// batching argument as `timelineEpoch`: every working row's TimelineView
    /// ticks at the same wall-clock instants, so SwiftUI runs one layout
    /// pass per tick regardless of how many rows are .working.
    fileprivate static let workingTickInterval: TimeInterval = 0.45

    var body: some View {
        let activity = activityProvider()
        switch activity.state {
        case .working:
            CasperWorkingDotsIndicator(color: selectedColor ?? .blue)
        case .needsInput, .done:
            if let date = activity.lastActivityAt {
                TimelineView(.periodic(from: Self.timelineEpoch, by: 30)) { context in
                    Text(CasperRelativeTime.shortString(since: date, now: context.date))
                        .font(timeFont)
                        .foregroundColor(textColor(for: activity.state))
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
        case .none:
            EmptyView()
        }
    }

    private func textColor(for state: CasperWorkspaceActivityState) -> Color {
        if let selectedColor { return selectedColor }
        return state == .needsInput ? .blue : doneColor
    }
}

/// Three-dot working indicator. Lights one dot at a time, cycling left→right,
/// mimicking SF Symbols' `.variableColor.iterative` look without installing a
/// per-row continuous `CAAnimation`. See `CasperWorkspaceActivityIndicator`
/// header for the foreground-freeze backstory.
private struct CasperWorkingDotsIndicator: View {
    let color: Color

    private static let dotSize: CGFloat = 3
    private static let dotSpacing: CGFloat = 1.5
    private static let dimOpacity: Double = 0.32

    var body: some View {
        TimelineView(
            .periodic(
                from: CasperWorkspaceActivityIndicator.timelineEpoch,
                by: CasperWorkspaceActivityIndicator.workingTickInterval
            )
        ) { context in
            let elapsed = context.date.timeIntervalSince(
                CasperWorkspaceActivityIndicator.timelineEpoch
            )
            let phase = Int(elapsed / CasperWorkspaceActivityIndicator.workingTickInterval) % 3
            HStack(spacing: Self.dotSpacing) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(color)
                        .opacity(idx == phase ? 1.0 : Self.dimOpacity)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                }
            }
        }
    }
}
