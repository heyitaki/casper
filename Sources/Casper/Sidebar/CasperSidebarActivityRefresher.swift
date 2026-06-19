// CASPER: bridge from each visible workspace's narrow statusEntries publisher
// (`Workspace.sidebarActivityObservationPublisher`) into a single
// ObservableObject the compact `VerticalTabsSidebar` observes. Bumps a
// generation counter on a throttled cadence so the sidebar body re-evals
// `activityByID` and the "3 blue dots" indicator on agent state flips.
//
// Background: after commit 73d79ad0 moved statusEntries onto a private
// sub-ObservableObject (so the heavy `WorkspaceContentView` subtree no
// longer invalidates on every agent hook write), there was no path from
// the sub-store into the compact sidebar's observation graph. The
// non-compact `TabItemView` keeps working because it owns a per-row
// `.onReceive(tab.sidebarObservationPublisher)` subscription; the
// compact path's rows are `.equatable()` and rely on the sidebar's
// parent body re-evaluating to pick up activity changes. Without this
// refresher, the dots only updated when something else nudged the
// sidebar (tabManager publish, 20s `CasperClaudeActivityStore` JSONL
// mtime poll for claude only, modifier-key monitor, etc.) — so the
// indicator was intermittent for claude and basically silent for codex,
// gemini, and other agents that don't write to `~/.claude/projects`.
//
// Delete with the activity-state patch if upstream lands a first-class
// agent state surface on Workspace.

import Combine
import Foundation

@MainActor
final class CasperSidebarActivityRefresher: ObservableObject {
    /// Bumped on each throttled status-change emission. The sidebar reads
    /// this in body so SwiftUI's @StateObject subscription forces a
    /// re-eval; the value itself is informational (debug logs, change
    /// detection in `.onChange` if ever needed).
    @Published private(set) var generation: UInt64 = 0

    private let bumpSubject = PassthroughSubject<Void, Never>()
    private var bumpCancellable: AnyCancellable?
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]

    init() {
        // Throttle bumps so a hook-burst turn (prompt-submit + N
        // pre-tool-use + stop = ~5-12 writes) folds into a small number
        // of sidebar re-evals instead of one per write. 80ms is below
        // the "agent started thinking" perceptual threshold but long
        // enough to coalesce typical bursts. `latest: true` guarantees
        // the trailing event in a burst (the final Stop → Idle, or the
        // last Running → Needs input flip) still propagates.
        //
        // Worst-case load: at N=50 workspaces all generating concurrent
        // agent hook activity, upstream rate is bounded by hook write
        // cadence (sub-Hz per workspace under normal use). The throttle
        // caps the published rate at ~12.5 Hz regardless.
        bumpCancellable = bumpSubject
            .throttle(
                for: .milliseconds(80),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] in
                guard let self else { return }
                self.generation &+= 1
            }
    }

    /// Reconcile per-workspace subscriptions with the current visible set.
    /// Never call from view `body` — writes private state and would feed
    /// the @Published bump back through SwiftUI's body computation, tripping
    /// the "no state mutation inside view-body computations" rule in CLAUDE.md.
    func sync(workspaces: [Workspace]) {
        let currentIds = Set(workspaces.map(\.id))

        for id in workspaceCancellables.keys where !currentIds.contains(id) {
            workspaceCancellables.removeValue(forKey: id)
        }

        let subject = bumpSubject
        var openedNewSubscription = false
        for workspace in workspaces where workspaceCancellables[workspace.id] == nil {
            workspaceCancellables[workspace.id] = workspace
                .sidebarActivityObservationPublisher
                .sink { _ in subject.send(()) }
            openedNewSubscription = true
        }

        // Cold-start recovery: a statusEntries write that fired between
        // Workspace creation and this first subscription is never delivered
        // (PassthroughSubject has no replay). Send a synthetic bump so the
        // throttle window forces one re-eval that reads current statusEntries
        // directly. Cheap insurance; the throttle coalesces with any real
        // event already queued.
        if openedNewSubscription {
            subject.send(())
        }
    }
}
