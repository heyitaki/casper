import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// CASPER: covers the sidebar's three-level row highlight — the focused panel of
/// the selected workspace renders solid blue, its sibling panels render the
/// lighter wash, and everything else renders clear. Regression guard for the
/// highlight going stale when focus moves between panels of an already-selected
/// workspace (no `selectedTabId` change, so nothing published the move).
@MainActor
final class CasperSidebarHighlightTests: XCTestCase {

    /// Builds a workspace with two terminal panels and returns (workspace, first, second).
    private func makeTwoPanelWorkspace() throws -> (Workspace, UUID, UUID) {
        let workspace = Workspace()
        let first = try XCTUnwrap(workspace.focusedPanelId)
        let second = try XCTUnwrap(
            workspace.newTerminalSplit(from: first, orientation: .horizontal)
        ).id
        return (workspace, first, second)
    }

    private func entries(
        for workspace: Workspace,
        selected: UUID?
    ) -> [CasperSidebarPanelEntry] {
        CasperSidebarPanelEntryBuilder.entries(
            from: [workspace],
            selectedWorkspaceId: selected,
            activityByWorkspaceId: [:],
            notificationStore: TerminalNotificationStore.shared
        )
    }

    /// Every panel of the selected workspace must carry `isWorkspaceSelected`,
    /// so siblings of the focused panel render the wash rather than clear.
    func testAllPanelsOfSelectedWorkspaceAreMarkedWorkspaceSelected() throws {
        let (workspace, first, second) = try makeTwoPanelWorkspace()
        let built = entries(for: workspace, selected: workspace.id)

        XCTAssertEqual(built.count, 2, "Both terminal panels should emit a row")
        XCTAssertTrue(
            built.allSatisfy(\.isWorkspaceSelected),
            "Sibling panels of the selected workspace must stay workspace-selected"
        )
        XCTAssertEqual(
            Set(built.map(\.key.panelId)),
            Set([first, second])
        )
    }

    /// Exactly one row is the focused one, and it tracks `focusedPanelId`.
    func testExactlyOnePanelIsFocusedAndMatchesWorkspace() throws {
        let (workspace, _, _) = try makeTwoPanelWorkspace()
        let built = entries(for: workspace, selected: workspace.id)

        XCTAssertEqual(built.filter(\.isPanelFocused).count, 1)
        XCTAssertEqual(
            built.first(where: \.isPanelFocused)?.key.panelId,
            workspace.focusedPanelId
        )
    }

    /// The core regression: moving focus between panels of the already-selected
    /// workspace must move the solid-blue row.
    func testFocusMoveBetweenSiblingPanelsMovesTheFocusedRow() throws {
        let (workspace, first, second) = try makeTwoPanelWorkspace()

        workspace.focusPanel(first)
        var built = entries(for: workspace, selected: workspace.id)
        XCTAssertEqual(built.first(where: \.isPanelFocused)?.key.panelId, first)

        workspace.focusPanel(second)
        built = entries(for: workspace, selected: workspace.id)
        XCTAssertEqual(
            built.first(where: \.isPanelFocused)?.key.panelId,
            second,
            "Focus move must re-target the solid-blue row"
        )
    }

    /// The sidebar rebuilds its entries only when something publishes. bonsplit's
    /// focus state is not `@Published` and `selectedTabId` does not change when
    /// focus moves *within* the selected workspace, so without this signal the
    /// solid-blue row stays stuck on the previously focused panel.
    func testFocusMoveWithinWorkspacePublishesSidebarFocusSignal() throws {
        let (workspace, first, second) = try makeTwoPanelWorkspace()
        workspace.focusPanel(first)

        var fired = 0
        let cancellable = workspace.sidebarFocusObservationPublisher.sink { fired += 1 }
        defer { cancellable.cancel() }

        workspace.focusPanel(second)
        XCTAssertEqual(fired, 1, "A focus move must publish so the sidebar rebuilds entries")

        // Re-focusing the same panel must not churn the sidebar.
        workspace.focusPanel(second)
        XCTAssertEqual(fired, 1, "Re-focusing the same panel must not publish")
    }

    /// Behavior guard on the fix *seam* itself. The tests above prove the two
    /// halves in isolation — the publisher fires and the builder computes the
    /// highlight — but all of them stay green even if the
    /// `Publishers.Merge(.., sidebarFocusObservationPublisher)` line in
    /// `CasperSidebarActivityRefresher.sync` is reverted, which is exactly the
    /// regression the user reported. This drives the real refresher and asserts
    /// a focus move reaches its throttled `generation` counter through the
    /// merged focus publisher.
    func testRefresherGenerationAdvancesOnFocusMove() throws {
        let (workspace, first, second) = try makeTwoPanelWorkspace()
        workspace.focusPanel(first)

        let refresher = CasperSidebarActivityRefresher()
        refresher.sync(workspaces: [workspace])

        // Let the cold-start synthetic bump settle through the 80ms throttle so
        // the focus move is measured from a quiet baseline. An inverted
        // expectation is XCTest's way to advance the main run loop (where the
        // throttle timer fires) for a fixed span.
        let settle = expectation(description: "cold-start bump settles")
        settle.isInverted = true
        wait(for: [settle], timeout: 0.3)
        let baseline = refresher.generation

        workspace.focusPanel(second)

        let propagate = expectation(description: "focus bump propagates through throttle")
        propagate.isInverted = true
        wait(for: [propagate], timeout: 0.3)

        XCTAssertGreaterThan(
            refresher.generation,
            baseline,
            "A focus move must bump the refresher's generation via the merged focus publisher"
        )
    }

    /// Panels of an unselected workspace render clear.
    func testPanelsOfUnselectedWorkspaceAreNotHighlighted() throws {
        let (workspace, _, _) = try makeTwoPanelWorkspace()
        let built = entries(for: workspace, selected: UUID())

        XCTAssertFalse(built.contains(where: \.isWorkspaceSelected))
    }
}
