import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage of the Casper sidebar's session-timestamp pipeline:
/// relative-time rendering, Claude JSONL path resolution, and the scoped
/// activity classification that feeds each row's trailing time.
@MainActor
final class CasperSidebarTimestampTests: XCTestCase {

    // MARK: - CasperRelativeTime.shortString

    private func age(_ seconds: TimeInterval, now: Date = Date(timeIntervalSince1970: 2_000_000_000)) -> String {
        CasperRelativeTime.shortString(since: now.addingTimeInterval(-seconds), now: now)
    }

    func testShortStringSubMinuteAndFutureCollapseToUnderOneMinute() {
        XCTAssertEqual(age(0), "<1m")
        XCTAssertEqual(age(59), "<1m")
        // Future dates (clock skew) clamp rather than crash or go negative.
        XCTAssertEqual(age(-3600), "<1m")
    }

    func testShortStringMinuteHourDayBoundaries() {
        XCTAssertEqual(age(60), "1m")
        XCTAssertEqual(age(59 * 60 + 59), "59m")
        XCTAssertEqual(age(3600), "1h")
        XCTAssertEqual(age(23 * 3600 + 59 * 60), "23h")
        XCTAssertEqual(age(24 * 3600), "1d")
        XCTAssertEqual(age(6 * 86_400), "6d")
        XCTAssertEqual(age(7 * 86_400), "1w")
    }

    /// Regression: ages in [364d, 365d) used to render "0y" — `weeks` hit 52
    /// (skipping the week branch) while `days / 365` was still 0.
    func testShortStringYearBoundaryNeverRendersZeroYears() {
        XCTAssertEqual(age(363 * 86_400), "51w")
        XCTAssertEqual(age(364 * 86_400), "52w")
        XCTAssertEqual(age(365 * 86_400), "1y")
        XCTAssertEqual(age(729 * 86_400), "1y")
        XCTAssertEqual(age(730 * 86_400), "2y")
    }

    // MARK: - Claude JSONL path encoding

    /// Regression: the encoder used to replace only "/" with "-", but Claude
    /// Code dash-encodes every non-alphanumeric character of the cwd
    /// (`replace(/[^a-zA-Z0-9]/g, "-")`). Sessions launched from directories
    /// containing "." or "_" resolved to a nonexistent project dir and never
    /// surfaced a sidebar timestamp.
    func testClaudeJSONLPathEncodesNonAlphanumericsLikeClaudeCode() {
        let home = NSHomeDirectory()

        XCTAssertEqual(
            CasperClaudeSessionPath.jsonlPath(sessionId: "abc", cwd: "/Users/x/code/cmux"),
            "\(home)/.claude/projects/-Users-x-code-cmux/abc.jsonl"
        )
        XCTAssertEqual(
            CasperClaudeSessionPath.jsonlPath(sessionId: "abc", cwd: "/Users/x/code/heyitaki.github.io"),
            "\(home)/.claude/projects/-Users-x-code-heyitaki-github-io/abc.jsonl"
        )
        XCTAssertEqual(
            CasperClaudeSessionPath.jsonlPath(sessionId: "abc", cwd: "/Users/x/.worktrees/my_repo"),
            "\(home)/.claude/projects/-Users-x--worktrees-my-repo/abc.jsonl"
        )
    }

    // MARK: - Scoped activity classification

    private func entry(value: String, timestamp: Date) -> SidebarStatusEntry {
        SidebarStatusEntry(key: "claude_code", value: value, timestamp: timestamp)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testClassifyDoneTakesMaxOfScopedCandidates() {
        let activity = CasperAgentActivity.classifyActivity(
            agentEntries: [entry(value: "Idle", timestamp: base)],
            unreadCount: 0,
            notificationDate: base.addingTimeInterval(-100),
            claudeHistoryDate: base.addingTimeInterval(50),
            codexHistoryDate: base.addingTimeInterval(-500)
        )
        XCTAssertEqual(activity.state, .done)
        XCTAssertEqual(activity.lastActivityAt, base.addingTimeInterval(50))
    }

    /// Regression: classification used to hardwire workspace-level history
    /// dates, so a panel row inherited its most-recently-active sibling's
    /// time. After the fix the caller passes scoped candidates: a panel whose
    /// own history is old must NOT report a newer (sibling) date it wasn't
    /// given, and two panels given different scoped dates report different
    /// times.
    func testClassifyUsesOnlyTheCandidatesItWasGiven() {
        let stalePanel = CasperAgentActivity.classifyActivity(
            agentEntries: [entry(value: "Idle", timestamp: base.addingTimeInterval(-7200))],
            unreadCount: 0,
            notificationDate: nil,
            claudeHistoryDate: base.addingTimeInterval(-7200),
            codexHistoryDate: nil
        )
        let freshPanel = CasperAgentActivity.classifyActivity(
            agentEntries: [entry(value: "Idle", timestamp: base)],
            unreadCount: 0,
            notificationDate: nil,
            claudeHistoryDate: base,
            codexHistoryDate: nil
        )
        XCTAssertEqual(stalePanel.lastActivityAt, base.addingTimeInterval(-7200))
        XCTAssertEqual(freshPanel.lastActivityAt, base)
    }

    func testClassifyStatePrecedenceUnchanged() {
        let working = CasperAgentActivity.classifyActivity(
            agentEntries: [entry(value: "Running", timestamp: base)],
            unreadCount: 3,
            notificationDate: base,
            claudeHistoryDate: base.addingTimeInterval(60),
            codexHistoryDate: nil
        )
        XCTAssertEqual(working.state, .working)
        // Working rows sort by their newest scoped candidate, not just the
        // status-entry timestamp — a long-running stream keeps bubbling.
        XCTAssertEqual(working.lastActivityAt, base.addingTimeInterval(60))

        let needsInput = CasperAgentActivity.classifyActivity(
            agentEntries: [entry(value: "Needs input", timestamp: base)],
            unreadCount: 0,
            notificationDate: nil,
            claudeHistoryDate: nil,
            codexHistoryDate: nil
        )
        XCTAssertEqual(needsInput.state, .needsInput)

        let unreadOnly = CasperAgentActivity.classifyActivity(
            agentEntries: [entry(value: "Idle", timestamp: base)],
            unreadCount: 1,
            notificationDate: base.addingTimeInterval(5),
            claudeHistoryDate: nil,
            codexHistoryDate: nil
        )
        XCTAssertEqual(unreadOnly.state, .needsInput)

        let none = CasperAgentActivity.classifyActivity(
            agentEntries: [],
            unreadCount: 0,
            notificationDate: nil,
            claudeHistoryDate: nil,
            codexHistoryDate: nil
        )
        XCTAssertEqual(none.state, .none)
        XCTAssertNil(none.lastActivityAt)

        // No agent entries but history exists → done (restored workspace whose
        // hooks haven't re-fired yet).
        let historyOnly = CasperAgentActivity.classifyActivity(
            agentEntries: [],
            unreadCount: 0,
            notificationDate: nil,
            claudeHistoryDate: base,
            codexHistoryDate: nil
        )
        XCTAssertEqual(historyOnly.state, .done)
        XCTAssertEqual(historyOnly.lastActivityAt, base)
    }
}
