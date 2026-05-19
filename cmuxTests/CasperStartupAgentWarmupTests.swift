import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CasperStartupAgentWarmupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var recentTs: TimeInterval { now.timeIntervalSince1970 - 60 * 60 }

    func testRanksByExplicitTimestampAndSkipsSelected() {
        let selected = UUID()
        let recentA = UUID()
        let recentB = UUID()
        let older = UUID()

        let pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)] = [
            (selected, workspaceSnapshot(agent: true, statusTimestamp: recentTs)),
            (recentA, workspaceSnapshot(agent: true, statusTimestamp: recentTs - 100)),
            (recentB, workspaceSnapshot(agent: true, statusTimestamp: recentTs - 200)),
            (older, workspaceSnapshot(agent: true, statusTimestamp: recentTs - 9999)),
        ]

        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: selected
        )

        XCTAssertEqual(result, [recentA, recentB, older])
    }

    func testWarmsAgentWorkspacesWithNoTimestampSignal() {
        let a = UUID()
        let b = UUID()

        // No status / log entries at all — falls back to tab order.
        let pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)] = [
            (a, workspaceSnapshot(agent: true)),
            (b, workspaceSnapshot(agent: true)),
        ]

        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: nil
        )

        XCTAssertEqual(result, [a, b])
    }

    func testCapsAtMaxFive() {
        let ids = (0..<8).map { _ in UUID() }
        let pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)] = (0..<8).map { i in
            (ids[i], workspaceSnapshot(
                agent: true,
                statusTimestamp: recentTs - TimeInterval(i * 10)
            ))
        }

        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: nil
        )

        XCTAssertEqual(result.count, CasperStartupAgentWarmup.maxWorkspacesToWarm)
        XCTAssertEqual(result, Array(ids.prefix(CasperStartupAgentWarmup.maxWorkspacesToWarm)))
    }

    func testSkipsWorkspacesWithoutAgentPanel() {
        let withAgent = UUID()
        let noAgent = UUID()
        let pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)] = [
            (withAgent, workspaceSnapshot(agent: true, statusTimestamp: recentTs)),
            (noAgent, workspaceSnapshot(agent: false, statusTimestamp: recentTs)),
        ]

        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: nil
        )

        XCTAssertEqual(result, [withAgent])
    }

    func testNonAgentStatusKeysStillRankWorkspace() {
        // Even non-agent status entries (e.g. "git") provide a valid recency
        // signal — the agent panel presence is what qualifies, the timestamp
        // is just for ordering.
        let id = UUID()
        let pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)] = [
            (id, workspaceSnapshot(
                agent: true,
                statusEntries: [
                    SessionStatusEntrySnapshot(
                        key: "git",
                        value: "clean",
                        icon: nil,
                        color: nil,
                        timestamp: recentTs
                    )
                ]
            ))
        ]

        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: nil
        )

        XCTAssertEqual(result, [id])
    }

    func testLogEntryTimestampDrivesRanking() {
        // A workspace with no status entries but a log entry still ranks by
        // that log entry's timestamp, ahead of a workspace with no signal at
        // all (which falls back to tab order).
        let logRanked = UUID()
        let plain = UUID()

        // `plain` is first in tab order so tab-order fallback would put it
        // ahead; only the log timestamp on the second pair can flip this.
        let pairs: [(id: UUID, workspace: SessionWorkspaceSnapshot)] = [
            (plain, workspaceSnapshot(agent: true)),
            (logRanked, workspaceSnapshot(
                agent: true,
                logEntries: [
                    SessionLogEntrySnapshot(
                        message: "hi",
                        level: "info",
                        source: nil,
                        timestamp: recentTs
                    )
                ]
            )),
        ]

        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: pairs,
            selectedWorkspaceId: nil
        )

        XCTAssertEqual(result, [logRanked, plain])
    }

    func testEmptyWhenNoWorkspaces() {
        let result = CasperStartupAgentWarmup.workspaceIdsToWarm(
            pairs: [],
            selectedWorkspaceId: nil
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Helpers

    private func workspaceSnapshot(
        agent: Bool,
        statusTimestamp: TimeInterval? = nil,
        statusEntries: [SessionStatusEntrySnapshot]? = nil,
        logEntries: [SessionLogEntrySnapshot] = []
    ) -> SessionWorkspaceSnapshot {
        let resolvedEntries: [SessionStatusEntrySnapshot]
        if let statusEntries {
            resolvedEntries = statusEntries
        } else if let statusTimestamp {
            resolvedEntries = [
                SessionStatusEntrySnapshot(
                    key: "claude_code",
                    value: "Idle",
                    icon: nil,
                    color: nil,
                    timestamp: statusTimestamp
                )
            ]
        } else {
            resolvedEntries = []
        }

        let agentSnapshot: SessionRestorableAgentSnapshot? = agent
            ? SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "session-\(UUID().uuidString)",
                workingDirectory: "/tmp",
                launchCommand: nil
            )
            : nil
        let panelSnapshot = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: nil,
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: "/tmp",
                scrollback: nil,
                agent: agentSnapshot,
                tmuxStartCommand: nil
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil
        )

        return SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelSnapshot.id], selectedPanelId: panelSnapshot.id)),
            panels: [panelSnapshot],
            statusEntries: resolvedEntries,
            logEntries: logEntries,
            progress: nil,
            gitBranch: nil,
            remote: nil
        )
    }
}
