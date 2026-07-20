# Retired fork patches

Patches obviated by upstream merges. Register index: [`docs/casper-fork.md`](../casper-fork.md).

Obviated by the 2026-06-09 upstream merge (~1,830 commits):

- **File preview `.ts` routing** — upstream `knownTextResolutionBeforeMedia` (sniffs MPEG-TS byte patterns) supersedes the fork's text-extension fast path. Only the `isExplicitTextFile` shim remains for Finder-row icons.
- ~~**Fish shell integration (`vendor_conf.d/cmux-shell-integration.fish`)**~~ — **un-retired; see [agent-resume shell integration](agent-resume-shell-integration.md).** The 2026-06-09 merge retired this on the belief that upstream's `Resources/shell-integration/fish/config.fish` fully replaced it. It does not: upstream loads that file via the shell command (`fish -il --init-command`), which `GhosttyTerminalView.swift` applies only when `baseConfig.command` is empty. Restored agent panels always set an initial command, so they got no fish integration at all. The retirement also left the `XDG_DATA_DIRS` injection in place with nothing to find — a dangling hunk that should have been the tell. The wrapper rename to `cmux-claude-wrapper` was real and is kept. Note the re-added loader is *not* a copy of the original (which was a self-contained `claude`-wrapper installer, now obsoleted by upstream's `_cmux_install_cli_wrapper`); it is a thin loader that keeps two of the original's guards, `status is-interactive` and load-order safety.
- **Workspace sidebar grouping by repo path (old `CasperWorkspaceGroupSection`-wrapped-VStack render path)** — the 2026-06 merge temporarily dropped per-panel rows and repo-path grouping in favor of upstream's user-defined WorkspaceGroups. The feature was restored in the [compact sidebar](compact-sidebar.md) patch using a flat `CasperSidebarRenderPlan` + `LazyVStack` approach. `CasperWorkspaceGroupResolver`, `CasperWorkspaceGroups.swift`, and the new `CasperSidebarRenderPlan.swift` are all active fork files.
- **`CasperBoundedAsyncWorkPool` git-probe driver in TabManager** — upstream's `WorkspaceGitMetadataProbeLimiter` actor + directory-coalesced snapshot requests supersede it. The pool type remains for the warmup coordinator.
- **Cheap/heavy session-autosave fingerprint split** — upstream's `ProcessDetectedResumeIndexes` has no cheap path; dropped.
- **`WorkspaceSidebarMetadataStore` sub-store** — upstream's per-item snapshot architecture + event-driven `SharedLiveAgentIndex` address the original re-render concern; Workspace reverted to upstream's direct `@Published` layout.
- **Traffic-light debug offsets in WindowDecorationsController** — upstream stopped repositioning native titlebar buttons entirely.
- **`testNavigationFlashUsesGrayAccent`** — upstream unified all attention-flash styles onto the notification ring accent.
- **`collectAgentPIDsByWorkspace` single-pass scan in TerminalController** — upstream inlined equivalent logic in `socketListenerDidStart`.

Retired by the 2026-07 upstream merge:

- **Reopen-last-closed session** — upstream shipped `ClosedItemHistoryStore` + `AppDelegate.reopenMostRecentlyClosedItem` and a History menu. Full retirement note (including the known `.workspaceGroup` gap) in [session navigation](sidebar-session-navigation.md).
- **Bespoke sidebar `CasperForkSession` path** — upstream's restored/live snapshot gate and Fork Conversation destination dispatcher now power both Casper menus ([fork conversation](fork-conversation.md)); the PID-liveness gate, disk lookup, custom unavailable alert, and single-new-workspace action were deleted.
