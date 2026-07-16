# Casper Fork Changes (heyitaki/cmux)

`heyitaki/cmux` is a fork of `manaflow-ai/cmux`. We carry these local patches indefinitely; do not assume any will be upstreamed. The point of this doc is to make `git merge upstream/main` cheap by giving the merger a map of where fork-only hunks live, why they exist, and what would obviate them.

See `CLAUDE.md` → "Upstream merge strategy (Casper fork)" for the discipline. This file is the per-patch register that the discipline points at.

## Current merge debt

As of 2026-06-09, `heyitaki/cmux:main` is **caught up** with `manaflow-ai/cmux:main` via the latest `git merge upstream/main` (~1,830 upstream commits merged, including the project rename to `cmux.xcodeproj`, the `@Observable SidebarDragState` sidebar rewrite, first-class workspace groups, upstream fish integration, and the CmuxControlSocket extraction). Both submodules were sub-merged and pushed to their heyitaki fork `main` branches first (ghostty `813986fdf`, bonsplit `1541b4ae`).

Patches retired by this merge are listed under "Retired fork patches" at the bottom.

**Hot paths to preserve during future conflict resolution.** `TerminalWindowPortal.hitTest()` and `BrowserWindowPortal.hitTest()` are typing-latency-critical (see `CLAUDE.md` → "Pitfalls"). Upstream replaced the manual `isPointerEvent` guard with `WindowInputRoutingContext.allowsPortalPointerHitTesting` — semantically equivalent; keep that guard and the interior-point early-reject intact.

## Fork update checklist

1) Land the change on `main` (or via PR against `heyitaki/cmux`).
2) Add or update the section in this file describing what was touched and why.
3) If the change modifies any upstream cmux file, add a `// CASPER: <reason>; delete if upstream adds <X>` comment on the modified hunk so the next merger can grep for it.
4) Add the touched upstream files to "Merge conflict notes" below if they're not already listed.

## Current fork patches

### 1) Casper fork infrastructure

- Files:
  - `CLAUDE.md` (upstream merge strategy section), `CONTRIBUTING.md`, `docs/ghostty-fork.md`
  - `.gitmodules` (ghostty.url → heyitaki/ghostty, vendor/bonsplit.url → heyitaki/bonsplit)
  - `.github/workflows/build-ghosttykit.yml`, `test-depot.yml`, `test-e2e.yml` (heyitaki release URLs; upstream's flavored tag format `xcframework-<sha>-<flavor>` adopted as of the 2026-06 merge)
  - `scripts/ensure-ghosttykit.sh` (heyitaki URL + upstream `GHOSTTY_CLEAN_KEY` flavor key)
  - `ghostty`, `vendor/bonsplit` submodule pins
- Summary:
  - Points submodules and xcframework release URLs at heyitaki forks so cloning doesn't require write access to manaflow repos. `GHOSTTY_RELEASE_TOKEN` must grant write to heyitaki/ghostty.
  - heyitaki/ghostty:main carries one fork commit (pty resize debounce, `c6302d022`) merged with manaflow upstream; the tee callback it introduced is now upstream's `ghostty_surface_set_pty_tee_cb` embedder API, so only the resize-debounce remains fork-specific.
  - heyitaki/bonsplit:main carries: `.never` case added to upstream's top-level `TabBarVisibility` enum, and the own-double-click guard in the tab-bar background view (window-scoped `clickCount` fix). The former fork `.auto` case was renamed onto upstream's `.multipleTabs`.
- Deletion condition:
  - Fork-boundary infra; stays until heyitaki/cmux retires. The bonsplit double-click guard is a clean upstream PR candidate.

### 2) Minimal-mode sidebar and reveal strips

- Files (Casper-only): `Sources/Casper/Sidebar/SidebarRevealStrip.swift`, `AppDelegate+SidebarRevealEdgeMouseHandler.swift`, `WindowHostView+SidebarRevealPassThrough.swift`
- Files (upstream files modified — primary conflict surface):
  - `Sources/ContentView.swift` (reveal-strip wiring, zeroed traffic-light inset, conditional titlebar strip in minimal+collapsed mode)
  - `Sources/AppDelegate.swift` (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept)
  - `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift` (`hitTest()` pass-through bands)
  - `Sources/Update/UpdateTitlebarAccessory.swift` + `Sources/Update/MinimalModeSidebarControls.swift` + `Sources/WindowDragHandleView.swift` (trimmed sidebar-top button cluster, see merge note below; `CasperReloadTitlebarButton` injection; hint-interval shift via `TitlebarControlsLayoutMetrics.casperReloadButtonShift`)
  - `Sources/App/WorkspaceRuntimeSettings.swift` (default to minimal presentation)
  - `Resources/Localizable.xcstrings`
  - `cmuxTests/AppDelegateShortcutRoutingTests.swift`, `cmuxTests/InactivePaneFirstClickFocusTests.swift`
- Summary:
  - Workspace defaults to minimal presentation; hidden-sidebar gap replaced with a 5pt reveal strip on each edge (click expands sidebar, drag resizes window). `cmux_sendEvent` captures the click before AppKit resize tracking; portals pass through the same band.
  - 2026-06 merge note: upstream rewrote `TitlebarControlsView` (five buttons: toggle sidebar, new tab, notifications, focus-history back/forward; no `slots:` API). Casper trims the cluster to **New Tab + the DEBUG reload button** via `MinimalModeSidebarControlActionSlot.visibleSlots` (single source of truth, `[.newTab]` when branded). All consumers derive from it: `controlsGroup` rendering, `TitlebarControlsHitRegions` rect math (with `casperReloadButtonShift` so AppKit click targets align past the reload button), `computedHostWidth` (stock classic still = 164), and the hint-pill intervals (positions are visible-index based). Toggle sidebar / notifications / focus history are absent in branded builds — the edge reveal strip reopens the sidebar.
- Deletion condition:
  - Delete the intercept + pass-through when upstream adds equivalent edge-reveal affordances. Delete default-to-minimal if upstream adopts it.

### 3) Panel right-click context menu unification (+ #3890 parity)

- Files added: `Sources/Panels/PanelCloseTabContextMenu.swift`
- Files (upstream files modified): `Sources/GhosttyTerminalView.swift` (rightMouseDown forwarding under mouse capture; `appendPanelTabActions` replaces upstream's `appendMoveCurrentSurfaceMoveMenuItems`), `Sources/Panels/CmuxWebView.swift`, `BrowserPanel.swift`, `MarkdownPanelView.swift`, `FilePreviewPanel.swift`, `FilePreviewTextEditor.swift`, `FilePreviewMagnifyingPDFView.swift`, `Sources/AppDelegate.swift` + `Sources/CmuxConfig.swift` + `Sources/CmuxSurfaceTabBarBuiltInAction.swift` (shortcut display via `menuShortcut`)
- Files removed (relative to upstream): `CmuxWebView+CloseTab.swift`, `CmuxWebView+MoveTabToNewWorkspace.swift`, `BrowserPanel+CloseTab.swift`, `BrowserPanel+MoveTabToNewWorkspace.swift`, `GhosttyNSView+MoveTabToNewWorkspace.swift`
- Summary:
  - Single shared menu path for Split/New Tab/Close Tab/Move Tab across all panels. Upstream #3890 ("move tab into existing workspace" submenu) was ported into `PanelTabActions`/`PanelTabActionMenuController` during the 2026-06 merge so all panels get it, using upstream's `terminalContextMenu.moveTab*` strings.
  - Terminal right-click under mouse capture (vim `mouse=a`, tmux) forwards PRESS+RELEASE to the PTY and still presents the menu.
- Deletion condition:
  - If upstream unifies its per-panel menu duplication, fold into theirs and keep only `menuShortcut` plumbing.

### 4) bonsplit `.never`/`.multipleTabs` + heyitaki/bonsplit submodule

- Files: `.gitmodules`, `vendor/bonsplit` pin, `Sources/Workspace.swift` (top-level `tabBarVisibility: .multipleTabs` in `BonsplitConfiguration`), `Sources/GhosttyTerminalView.swift` (New Tab right-click item), `Resources/Localizable.xcstrings`
- Summary:
  - Upstream shipped its own top-level `TabBarVisibility` (.always/.multipleTabs). cmux/Casper sets `.multipleTabs` so terminals stay tabless until a pane has >1 tab. The fork's bonsplit adds `.never` (host-managed chrome) on top, plus the own-double-click guard.
- Deletion condition:
  - If upstream cmux adopts `.multipleTabs` by default, the Workspace.swift hunk dissolves; `.never` stays fork-side until upstream wants it.

### 5) Bundled universal ripgrep for Find pane

- Files added: `scripts/ensure-ripgrep.sh`, `scripts/ripgrep-checksums.txt`
- Files (upstream files modified):
  - `Sources/FileExplorerSearchController.swift` (bundled `Resources/bin/rg` is the highest-priority candidate inside upstream's `RipgrepExecutableResolver` search order, after an explicitly configured custom path; plus fork pagination: `FileSearchOptions`, `loadMore()`, `FileSearchSnapshot.hasMore`, `FileSearchOutputPipeline(rootPath:hardMaxResults:initialEmissionTarget:)`)
  - `Sources/SessionIndexStore.swift` (rg resolution funnels through the same resolver)
  - `scripts/setup.sh`, `scripts/reload.sh`, `cmux.xcodeproj/project.pbxproj` ("Ensure ripgrep" PBXShellScriptBuildPhase + Copy CLI entry), `.github/workflows/release.yml`, `nightly.yml`, `.gitignore`
- Summary:
  - Bundles ripgrep universal binary at `Resources/bin/rg`; locator uses `Bundle.main.resourceURL` (not `Bundle.url(forResource:)` — copy-files-phase artifacts are invisible to it). 2026-06 merge folded the bundle-first lookup into upstream's `RipgrepExecutableResolver` (which brought Nix paths and a configured-custom-path setting).
- Deletion condition:
  - Delete when upstream bundles rg or replaces the search backend.

### 6) Minimal-mode window-movable policy

- Files (added): `Sources/Casper/Window/CasperMinimalModeWindowMovable.swift`
- Files (upstream files modified): `Sources/WindowDecorationsController.swift` (call after `applyMinimalModeSidebarTitlebarClickTarget(to:)` in `apply(to:)`), `Sources/ContentView.swift` (call after `configureCmuxMainWindowDragBehavior(window)` in the WindowAccessor refresh)
- Summary:
  - Forces `window.isMovable = false` on the main workspace window in minimal mode so AppKit's auto-titlebar-drag can't hijack bonsplit tab drags. Upstream's `configureCmuxMainWindowDragBehavior` and `WindowMoveSuppressionSequence` (depth-tracked, restores previous state) are compatible; the explicit call may now be partially redundant with upstream's drag behavior setup — re-evaluate at the next merge.
- Deletion condition:
  - Delete if upstream's main-window drag configuration provably covers minimal-mode bonsplit tab drags (verify by dragging a tab in a minimal-mode Casper build with the call removed).

### 7) Compact one-line sidebar workspace row + session-first ordering + repo-path grouping

- Files (added): `Sources/Casper/Sidebar/CasperCompactWorkspaceRow.swift`, `CasperAgentActivity.swift`, `CasperSidebarActivityRefresher.swift`, `CasperSidebarSearchField.swift`, `CasperWorkspaceGroups.swift`, `CasperSidebarRenderPlan.swift`
- Files (upstream files modified):
  - `Sources/ContentView.swift` — `VerticalTabsSidebar` gains `workspaceGroupCollapseStore` (ObservedObject); `TabItemView` gains `casperActivity` (participates in the `Equatable` union); `isCasperCompact` gate in `TabItemView` body strips the activity glyph, unbolds the title, hides sub-rows; `casperWorkspaceRowsModel` pre-sorts tabs by `CasperAgentActivity.compareActivityDesc`, applies the workspace search filter (non-branded) or skips it (branded, panel-level filter applied instead), and builds the `CasperBrandedPlan` (flat render plan via `CasperSidebarRenderPlan.build`); `workspaceRows` forks on `model.brandedPlan`: branded path uses `brandedWorkspaceRows` (repo-group headers + `CasperSidebarPanelRow` in a LazyVStack ForEach); non-branded path uses upstream's `SidebarWorkspaceRenderItem.renderItems`; JSONL activity `.task` poll loop; workspace search bar + reserved-height inset.
- Summary:
  - In branded Casper builds, the sidebar is panel-keyed: each terminal panel gets its own row, sorted by most-recent agent activity within repo-path groups (chevron + folder-icon headers). Workspace groups use `CasperWorkspaceGroupResolver` (`.git` root detection) not upstream's user-defined WorkspaceGroups. `CasperSidebarRenderPlan.build` produces a flat `[CasperSidebarRenderItem]` suitable for `LazyVStack`; `CasperSidebarGroupHeaderRow` is a standalone header view with self-hover for the `+` button (replacing `CasperWorkspaceGroupSection` which wraps rows in a VStack).
  - Shift-click in the branded path ranges over `displayedWorkspaceIds` (the activity-sorted, post-collapse workspace order) rather than `tabManager.tabs` order; `lastSidebarSelectionIndex` stays in the `tabManager.tabs` index space for compatibility with drag machinery and the non-branded path.
  - Collapse state persisted in `CasperWorkspaceGroupCollapseStore` (UserDefaults). Headers hidden when there is only one group.
  - Activity model: hook-driven `Workspace.statusEntries` + Claude JSONL transcript recency, attributed strictly per-session. The snapshot-boundary rule still applies: rows receive value snapshots; activity reads happen above the row boundary.
- Deletion condition:
  - Delete if upstream ships a compact sidebar mode with inline last-activity and per-panel rows grouped by project/repo.

### 8) Restore-time agent workspace warmup (parallel)

- Files (added): `Sources/Casper/CasperStartupAgentWarmup.swift`, `Sources/Casper/Concurrency/CasperBoundedAsyncWorkPool.swift`, `cmuxTests/CasperStartupAgentWarmupTests.swift`
- Files (upstream files modified):
  - `Sources/AppDelegate.swift` (hooks in `applySessionWindowSnapshot` and `createMainWindow`, gated on `CasperBuildEnvironment.isBranded`)
  - `Sources/BackgroundWorkspacePrimeCoordinator.swift` (bounded `withTaskGroup` parallel prime driver, `Policy.maxConcurrentPrimes` = activeProcessorCount with thermal downshift; upstream's `.noSurfaceWork` early-exits folded in)
- Summary:
  - On launch, eagerly background-primes up to 5 agent workspaces so `claude --resume` etc. are live on first click. Reuses upstream's prime pipeline; only the selection policy and the parallel driver are fork-side.
  - The former cheap/heavy session-autosave fingerprint split was **dropped** in the 2026-06 merge: upstream's `ProcessDetectedResumeIndexes` has no process-scan-free cheap path. If autosave cost shows up in profiles again, rebuild the optimization against that API.
- Deletion condition:
  - Delete the warmup if upstream adds restore-time priming; delete the parallel driver if upstream's coordinator goes concurrent.

### 9) Sidebar footer trimmed to a settings entry point

- Files (upstream files modified): `Sources/ContentView.swift` (`SidebarFooter` reduced to gear button + popover; `VerticalTabsSidebar` drops `onSendFeedback`), `cmuxTests/InactivePaneFirstClickFocusTests.swift`, `cmuxUITests/SidebarHelpMenuUITests.swift`
- Summary: gear button (`SidebarSettingsMenuButton`) with Keyboard Shortcuts + Import Browser Data; UpdatePill/dev-banner/help links removed from this surface.
- Deletion condition: delete if upstream ships an equivalent compact settings affordance.

### 10) Find-sidebar ripgrep result ranking + grouped Find UI (flag-gated)

- Files (added): `Sources/Casper/Search/CasperSearchConfig.swift`, `CasperFileSearchRanking.swift`, `CasperFindResultsView.swift`, `CasperFindGroupedResults.swift`, `CasperFindPreviewSlice.swift`, `CasperFindFileIcon.swift`, `CasperFindUIConfig.swift`
- Files (upstream files modified): `Sources/FileExplorerSearchController.swift` (re-rank hook in `emit(status:isSearching:)`), `Sources/FileExplorerView.swift` (grouped results overlay wiring, source-file icon substitution via the `FilePreviewKindResolver.isExplicitTextFile` shim)
- Summary: groups hits by file, tiers by basename relevance; flag `CMUX_CASPER_SEARCH_RANKING=1` / `CasperSearchRankingEnabled`; on for Casper builds.
- Deletion condition: delete if upstream ships a ranked Find pipeline.

### 11) Debug-log gating for daily-driver DEBUG builds

- Files (added):
  - `Sources/Casper/Sidebar/CasperCompactWorkspaceRow.swift`
  - `Sources/Casper/Sidebar/CasperAgentActivity.swift`
- Files (upstream files modified):
  - `Sources/ContentView.swift` (`TabItemView.body` — adds `isCasperCompact` gate that strips an agent activity glyph from the title, unbolds it, inserts the activity indicator on the right of the title row, hides all below-title sub-rows, and indents leading padding to align with the workspace-group folder icon; `VerticalTabsSidebar.workspaceRows` sorts workspaces by activity recency before passing to `CasperWorkspaceGroupResolver.groups`)
  - `cmux.xcodeproj/project.pbxproj` (registers the new files)
- Summary:
  - In branded Casper builds, each sidebar workspace renders as a single line — a hover-revealed close button at the leading edge (chevron column), title (conversation topic, with workspace title's existing path fallback) next to it, and a right-pinned agent-state indicator on the trailing edge.
  - Display title is run through `CasperWorkspaceTitle.displayTitle()` which strips a leading agent activity glyph (Claude Code's `✱`, plain `*`, sparkle/star variants, `•`) plus following whitespace. Strip is render-only; `workspace.title` itself is unchanged so window titles and accessibility keep the raw string.
  - Title is rendered with `.regular` weight in compact mode (rich rows still use `.semibold`).
  - Below-title rows (custom description, latest-notification subtitle, remote section, metadata blocks, log entry, progress bar, branch/directory row, pull requests, listening ports) are hidden in compact mode.
  - The leading unread-count badge circle is suppressed in compact mode; the close button takes that slot instead and renders only on row hover. Width 10, frame-reserved so the title position is hover-stable. Layout: outer 6 + inner-leading 4 + close-slot 10 + HStack-spacing 5 = title at x=25, matching the workspace-group folder icon in `CasperWorkspaceGroupHeader` (chevron 10..20, folder at x=25). Vertical padding is reduced from 8 to 4 since rows are single-line.
  - Right edge is wrapped in `.fixedSize(horizontal: true, vertical: false)` and follows a `Spacer(minLength: 8)`, so a title that grows past the trailing edge truncates with `…` before it can shove the time/spinner off-screen. The trailing accessory is `CasperWorkspaceActivityIndicator`, which renders a 4-state activity model derived from cmux's hook-driven `Workspace.statusEntries` (see `CasperAgentActivity`):
    - `working` → blue 3-dot indicator (`CasperWorkingDotsIndicator`, three `Circle()` dots cycling left→right via a shared-epoch `TimelineView(.periodic(by: 0.45))`; no continuous `CAAnimation`). The earlier `Image(systemName: "ellipsis").symbolEffect(.variableColor.iterative, options: .repeating)` installed a per-row repeating `CAAnimation`, and with multiple concurrently-working workspaces it pressured the render server enough to produce a foreground-only freeze (cleared by backgrounding, since macOS pauses CA composition there). Triggered when any agent status entry has a non-terminal value (e.g. Claude Code "Running", verbose tool description, Codex "Running").
    - `needsInput` → blue relative-time. Triggered by an agent entry value matching "Needs input"/"Waiting", a codex-failure entry (red exclamation icon), or `notificationStore.unreadCount(forTabId:) > 0` while an agent entry is present.
    - `done` → secondary-colored relative-time. Agent entry exists with value "Idle".
    - `none` → hidden. No agent status entry — i.e. cmux's SessionEnd hook (Ctrl+C path) ran `clear_agent_pid … --clear-status`, or no agent has ever run in this workspace.
  - Activity timestamp (`lastActivityAt`, all non-`none` states) is the max across the caller-scoped candidates: agent `SidebarStatusEntry.timestamp` (set by cmux's CLI when the hook fires), notification `createdAt`, and the agent-history dates. Claude history is the JSONL transcript's last real `user`/`assistant` message timestamp, skipping `/resume` metadata and `/compact` summaries — see `CasperClaudeActivityIO.parseLatestRealActivity` — so a workspace that's been idle but had real conversation still shows accurate recency. `CasperAgentActivity.classifyActivity` is a pure function over those candidates; `activity(for:)` passes workspace-scoped ones and `panelActivity` passes panel-scoped ones (panel JSONL dates, per-surface unread/notification), so a panel row in a multi-panel workspace can't inherit a sibling's timestamp. JSONL attribution is always per-session: hook records (`~/.cmuxterm/claude-hook-sessions.json`, written by SessionStart) for live launches, and `Workspace.restoredAgentSnapshotsByPanelId[*].sessionId` for workspaces that came back from session persistence. The JSONL path encoding mirrors Claude Code's `replace(/[^a-zA-Z0-9]/g, "-")` (see `CasperClaudeSessionPath.jsonlPath` — dots/underscores dash-encode too, not just "/"). We deliberately do NOT fall back to "every JSONL under `~/.claude/projects/<encoded-cwd>/`" — that aggregated max(timestamp) across every sibling session in the cwd, pegging every workspace sharing a project root (e.g. all `~/code/pixie` tabs) to the most-recently-active sibling's time. Better to show no trailing time than a wildly misleading one. Cold-start paint comes from `~/.cmuxterm/casper-claude-activity-cache-v3.json`, keyed by JSONL path — workspace/panel UUIDs are minted fresh on every session restore, so the earlier UUID-keyed cache could never hit after a relaunch.
  - The indicator uses two `TimelineView(.periodic(from:by:))` schedules — one at 30s for the relative-time text and one at `workingTickInterval` (0.45s) for the working-dots phase — both anchored to a shared static `timelineEpoch` so every row's ticks align to the same wall-clock instants (so SwiftUI can batch them into one layout pass). The body re-reads the activity each tick so the relative-time text stays fresh without subscribing to `Workspace.objectWillChange` from inside a row body (which would violate the workspace-list snapshot-boundary rule).
  - Workspace ordering: `workspaceRows` runs a stable sort over the filtered tab list before grouping (`CasperAgentActivity.compareActivityDesc`): pinned workspaces first, then most-recent activity first within each partition, with `.none` workspaces sinking to the bottom. Ties preserve original `tabManager` order so identical states don't jitter between renders.
- Deletion condition:
  - Delete if upstream cmux adds a first-class compact sidebar mode that drops auxiliary rows and shows last-activity inline.
- Files: `Sources/FileDropOverlayViewHitTesting.swift`, `Sources/TerminalWindowPortal.swift` (stale-drag-pasteboard guards), `Sources/GhosttyTerminalView.swift` (`forceRefresh` skips healthy keystroke logging)
- Summary: prevents per-keystroke hitTest walks and log writes after any file drag; keeps diagnostics for real drags/anomalies.
- Deletion condition: delete if upstream rewrites the instrumentation.

### 12) Small CASPER hunks (grep `// CASPER:` for the authoritative list)

- Files (added):
  - `Sources/Casper/CasperStartupAgentWarmup.swift`
  - `cmuxTests/CasperStartupAgentWarmupTests.swift`
- Files (upstream files modified):
  - `Sources/AppDelegate.swift` (two one-line hooks in `applySessionWindowSnapshot` and `createMainWindow`, gated on `CasperBuildEnvironment.isBranded`, calling `CasperStartupAgentWarmup.applyStartupWarmup`)
  - `Sources/BackgroundWorkspacePrimeCoordinator.swift` (sequential `for` over pending IDs replaced with a rolling `withTaskGroup` capped at `min(pending, Policy.maxConcurrentPrimes)`, where the cap is `activeProcessorCount` with thermal-state downshift)
  - `cmux.xcodeproj/project.pbxproj` (registers the new files)
- Summary:
  - On Casper launch, eagerly background-prime agent workspaces so their `claude --resume` / `codex resume` / etc. sessions resume on app open instead of waiting for a manual click. Selection ranks by `max(statusEntries.timestamp, logEntries.timestamp)` with tab-order fallback, caps at 5 per restore, skips the already-selected workspace, and requires `panels[].terminal.agent` to be set in the snapshot (i.e., an agent was attached at last save).
  - Gated on `AgentSessionAutoResumeSettings.isEnabled()` — if the user disabled auto-resume, `restoredAgentResumeInput` is nil and a warmed shell would be empty.
  - Reuses the upstream `BackgroundWorkspacePrime` pipeline end to end (`requestBackgroundWorkspaceLoad` → `pendingBackgroundWorkspaceLoadIds` → coordinator hidden mount → surface start → `initialInput` flush). The only Casper-specific bit is the selection policy.
  - To prevent 5 sequential 2 s timeouts compounding to ~10 s, the coordinator now drives `primeBackgroundWorkspaceIfNeeded` in parallel via a bounded `withTaskGroup`. Cap is `min(pending, activeProcessorCount)` with thermal downshift (serious → cores/2, critical → 1). Per-workspace state stays serialized on `@MainActor`; parallelism is only across the suspension points in `waitForBackgroundWorkspacePrimeCompletion`. This parallelization is general and could be upstreamed independently of the Casper warmup selector.
- Deletion condition:
  - Delete `CasperStartupAgentWarmup` + the two AppDelegate hooks if upstream cmux adds a restore-time background prime over the existing `restoredAgentAutoResumePendingPanelIds` set.
  - Delete the `BackgroundWorkspacePrimeCoordinator` patch if upstream rewrites the coordinator to drive primes concurrently itself.

### Sidebar footer trimmed to a settings entry point

- Files (upstream files modified):
  - `Sources/ContentView.swift` (`SidebarFooter` / `SidebarFooterButtons` / `SidebarHelpMenuButton` reduced to a single gear button with a two-item popover; `VerticalTabsSidebar` drops `onSendFeedback` parameter)
  - `cmuxTests/InactivePaneFirstClickFocusTests.swift` (drops `onSendFeedback` from `VerticalTabsSidebar` initializer)
  - `cmuxUITests/SidebarHelpMenuUITests.swift` (removed `testHelpMenuCheckForUpdatesTriggersSidebarUpdatePill` / `testHelpMenuSendFeedbackOpensComposerSheet`; `testCmdOptionFWorksWithHiddenSidebar` now polls `SidebarSettingsMenuButton`/`Settings` instead of `SidebarHelpMenuButton`/`Help`)
- Summary:
  - Removes the "Development" label and `UpdatePill` from the sidebar footer; the only remaining footer element is the gear button.
  - Replaces the question-mark help button with a gear-shape settings button (`accessibilityIdentifier: "SidebarSettingsMenuButton"`); the popover keeps only "Keyboard Shortcuts" and "Import Browser Data…". All other entries (Welcome, Send Feedback, Docs, Changelog, GitHub, GitHub Issues, Discord, Check for Updates) are dropped from this surface — the Cmd+Opt+F feedback shortcut and command-palette Check-for-Updates still work.
- Deletion condition:
  - Delete if upstream cmux replaces the help button with an equivalent compact settings affordance.

### Find-sidebar ripgrep result ranking (flag-gated)

- Files (added):
  - `Sources/Casper/Search/CasperSearchConfig.swift`
  - `Sources/Casper/Search/CasperFileSearchRanking.swift`
- Files (upstream files modified):
  - `Sources/FileExplorerSearchController.swift` (one-line hook in `emit(status:isSearching:)` that re-ranks `results` through `CasperFileSearchRanking.rank` before publishing the snapshot)
  - `cmux.xcodeproj/project.pbxproj` (registers the two new files)
- Summary:
  - Stock cmux streams ripgrep matches into the Find pane in walk order with no grouping or relevance signal, so searching `game` in a large repo can surface twenty README hits before `Game.ts`. This patch groups hits by file and tiers files by basename relevance: tier 0 = basename stem equals the query, tier 1 = basename contains the query, tier 2 = body-only match. Within each tier files sort alphabetically by relative path; within each file hits sort by line number. The re-rank runs at the snapshot boundary so the streaming pipeline is untouched.
  - Enable with env `CMUX_CASPER_SEARCH_RANKING=1` or Info.plist key `CasperSearchRankingEnabled = YES`. Brand-name fallback turns it on for Casper builds and leaves stock cmux unchanged.
- Deletion condition:
  - Delete if upstream cmux ships its own ranked Find-sidebar pipeline (e.g. Zoekt/trigram index) that supersedes this post-hoc grouping.

### First-mouse gate scoped to true app-activation clicks

- Files (upstream files modified):
  - `Sources/App/CmuxMainWindow.swift` (`shouldCaptureInactiveFirstMouse` routes through new `FirstMouseGatePolicy.shouldCapture`, which additionally requires `NSApp.keyWindow == nil`)
  - `Sources/Casper/Sidebar/AppDelegate+SidebarRevealEdgeMouseHandler.swift` (DEBUG `sidebar.click.context` forensics log on every sidebar-band leftMouseDown, recording pre-dispatch key/active state)
- Summary:
  - Upstream's #3856 first-mouse gate (`FirstMouseGatedHostingOverlay` covering the whole sidebar) swallowed clicks whenever the main window wasn't key. When an in-app panel held key (notifications popover, command palette, two-phase activation restore), that turned the sidebar into a click dead zone until the main window regained key — observed in the field as "temporarily unable to switch sessions by clicking (plain/shift/cmd)". `NSApp.keyWindow == nil` discriminates true app-activation clicks (gate them, per #3856 intent) from in-app key borrowing (pass through).
- Deletion condition:
  - Delete if upstream scopes the gate to app-activation clicks (or removes the overlay).

### Activation-desync repair (sidebar dead until Space switch)

- Files:
  - `Sources/Casper/Sidebar/AppDelegate+CasperActivationDesyncRepair.swift` (new; `CasperActivationDesyncRepairPolicy` + repair hook)
  - `Sources/AppDelegate.swift` (upstream file; one CASPER-marked call into the repair in the window `cmux_sendEvent` leftMouseDown routing — placed after the chrome/reveal-strip interceptors so `makeKey()`'s deferred `didBecomeKey` work can't interleave with their `nextEvent` tracking loops)
  - `Sources/TerminalNotificationStore.swift` (upstream file; `AppFocusState.isAppActive()` falls back to `NSRunningApplication.current.isActive` so `.activeFocus` badge dismissal isn't dropped while desynced)
  - `Sources/Casper/Sidebar/AppDelegate+SidebarRevealEdgeMouseHandler.swift` (forensics log gains `sysActive`/`mods` fields)
- Summary:
  - Field forensics (2026-07, /tmp/cmux-debug-casper.log) showed multi-minute "sidebar dead" episodes where every sidebar click arrived with `key=0 main=0 appActive=0` while arrow-key events were still being delivered and consumed by the file explorer — i.e. the OS considered the app active while AppKit's `NSApp.isActive` was stuck false (missed `didBecomeActive`). In that state AppKit treats each click as an app-activation click, the system-side activation request no-ops ("already active"), no `didBecomeKey` ever fires, and the #3856 first-mouse gate swallows every click until the user forces a real deactivate→activate cycle (Space switch). The repair runs on leftMouseDown at main workspace windows when `NSApp.isActive == false`: it re-requests activation, and — only when `NSRunningApplication.current.isActive` proves the desync — restores key/main status directly so the same click already sees a key window. Genuine background clicks keep upstream's first-click-swallow UX.
- Deletion condition:
  - Delete if upstream resyncs `NSApp.isActive` after a missed `didBecomeActive` (or macOS fixes the cooperative-activation desync).

### Debug-log gating for daily-driver DEBUG builds

- Files (upstream files modified):
  - `Sources/FileDropOverlayViewHitTesting.swift` (`logHitTestDecision` guard requires an active capture/drag, not just lingering drag-pasteboard types)
  - `Sources/TerminalWindowPortal.swift` (`logDragRouteDecision` same stale-pasteboard guard fix)
  - `Sources/GhosttyTerminalView.swift` (`forceRefresh` skips logging healthy keystroke-driven refreshes; anomalous states and non-typing reasons still log)
- Summary:
  - The pinned Casper app is a DEBUG build used as a daily driver. The drag-routing debug logs gated on "drag pasteboard has relevant types" — but `NSPasteboard(.drag)` retains the last drag's types indefinitely, so after one file drag every keystroke/mouse-move paid a live `hitTest` + 6-level view-hierarchy walk + log write. `forceRefresh` additionally logged one line per keypress, growing `/tmp/cmux-debug-casper.log` into the millions of lines. All three sites keep their diagnostic value for actual drags / anomalous surface states.
- Deletion condition:
  - Delete if upstream rewrites the drag-overlay debug instrumentation or adds equivalent gating.
- `Sources/AppDelegate.swift` — `isModalOrSheetPresented` (gates alert key-equivalent scan per keystroke).
- `Sources/TerminalController.swift` — `shouldReplacePorts` guard on the ports `@Published` write.
- `Sources/VaultAgentProcessScanner.swift` — pid-keyed argv parse cache (`VaultAgentArgvCache`).
- `Sources/Workspace.swift` — `appendLog` compatibility seam (left from the sub-store retirement; fold into call sites when convenient).
- `CLI/cmux.swift` — Codex `prompt-submit` pushes the prompt as a soft sidebar title (`surface.set_title`).
- `Resources/bin/cmux-claude-wrapper` — no startup socket gate (hooks connect independently); shim self-detection also matches the renamed wrapper path.
- `Sources/RestorableAgentSession.swift` — `freshLaunchShellCommand` + orphan-transcript fallback for resume.

### Sidebar session navigation, context menu, ordering

Three related sidebar/session features. The reopen-last-closed part of this patch was **retired** in the 2026-07 upstream merge — see the retirement note below.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperSidebarNavigator.swift` (new) — rebuilds the displayed sidebar order and moves focus for ⌘↑/↓ (next/prev session) and ⌘⇧↑/↓ (next/prev workspace).
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `groups(from:)` now sorts rows *within* each folder group strictly by per-session recency (de-clump: a workspace's split-panels are no longer forced adjacent); added `CasperSidebarRowActions` bundle + the row `.contextMenu` (Rename / Pin / Duplicate / Open cwd / Reveal / Copy path / Close).
  - `Sources/Casper/Sidebar/CasperAgentActivity.swift` — added `compareEntryActivityDesc` (entry-level recency comparator).
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/KeyboardShortcutSettings.swift` — 4 new actions (`nextSession`/`prevSession`/`nextSessionWorkspace`/`prevSessionWorkspace`, default ⌘↑/↓ + ⌘⇧↑/↓); generalized the `reopenClosedBrowserPanel` label to "Reopen Closed Session".
  - `Sources/KeyboardShortcutContext.swift` — `.nonBrowserPanel` context for the 4 nav actions; `casperEventEditsTextInput(_:)` guard so ⌘↑/↓ stays text-nav in editing fields.
  - `Sources/AppDelegate.swift` — 4 nav dispatch arms (guarded by the text-input check) → `CasperSidebarNavigator`.
  - `Sources/ContentView.swift` — `VerticalTabsSidebar` builds `CasperSidebarRowActions` per row (`casperSidebarRowActions`/`casperSessionWorkingDirectory`), hoisted `let rowActions` to keep the row initializer type-checkable.
  - `cmux.xcodeproj/project.pbxproj` — new `CasperSidebarNavigator.swift` build entry.
  - `Resources/Localizable.xcstrings` — new shortcut + context-menu strings (en/ja); updated reopen label.
  - `web/data/cmux-shortcuts.ts`, `web/data/cmux.schema.json` — the 4 new shortcut actions added to the public shortcuts reference + the `cmux.json` schema enum (shortcut policy requires both).
- Notes:
  - ⌘↑/↓ and ⌘⇧↑/↓ intentionally shadow Ghostty's jump-to-prompt inside a focused terminal (cmux's local monitor intercepts first). The text-input guard preserves ⌘↑/↓ as move-to-start/end inside editing fields.
- **RETIRED (2026-07 merge): reopen-last-closed.** Upstream shipped `ClosedItemHistoryStore` + `AppDelegate.reopenMostRecentlyClosedItem` (panel/workspace/window) and a History menu, satisfying this patch's deletion condition. `casperRecentlyClosedItems`, `CasperClosedItem`, `casperReopenLastClosedItem`, and `ClosedBrowserPanelRestoreSnapshot.panelSnapshot` were deleted; ⌘⇧T, the command palette, and the menu all route to upstream's path. **Known gap:** upstream's history has no `.workspaceGroup` entry, so "Close All Sessions" now undoes one workspace at a time instead of as one step — see the group-selection section.
- Deletion condition:
  - Delete the remainder if upstream adds first-class sidebar row keyboard nav and per-session row ordering/context menus.

### Sidebar group selection (⌘1…9), group context menu + batched close/reopen

Repurposes the numbered shortcut to operate on folder groups instead of single workspaces, and gives groups the same right-click affordances sessions already have.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperSidebarNavigator.swift` — extracted `orderedGroups()` (sorted+filtered, NOT collapse-filtered) under the existing `orderedEntries()`; added `selectGroup(digit:)` and `activeGroupKey(in:tabManager:)`. ⌘1 = top (most-recent) group; selecting a group expands it (if collapsed) and focuses its top session; pressing the same digit again (group already active) toggles its collapse and keeps the selection.
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `CasperWorkspaceGroupHeader` gained the ⌘N badge pill (moved off session rows), an `onCloseAll` closure, and a `.contextMenu` (New Session / Collapse-Expand / Close All Sessions); `CasperSidebarPanelRow` lost all its per-row ⌘N digit/pill plumbing (now group-level); `CasperWorkspaceGroupCollapseStore.expand(_:)` added.
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/AppDelegate.swift` — the `selectWorkspaceByNumber` dispatch is gated: in branded Casper builds the digit routes to `CasperSidebarNavigator.selectGroup(digit:)`; stock cmux keeps `selectTab(at:)`.
  - `Sources/ContentView.swift` — `workspaceRows` computes the per-group display digit (from the group's display offset), the distinct group workspace ids, and an `onCloseAll` closure; passes the new params to `CasperWorkspaceGroupSection`; the `CasperSidebarPanelRow` call site dropped the removed digit args.
  - `Sources/TabManager.swift` — `CasperClosedItem.workspaceGroup(items:)` case + `casperSuppressClosedItemRecording` flag (guards the per-workspace record in `closeWorkspace`); `casperCloseWorkspaceGroup(workspaceIds:)` snapshots all members, runs them through `closeWorkspacesWithConfirmation` under the flag, then pushes ONE group undo entry; `casperInsertClosedWorkspace` extracted from `casperReopenClosedWorkspace`; `casperReopenClosedWorkspaceGroup` reopens the whole group in one ⌘⇧T (re-selects the top session).
  - `Resources/Localizable.xcstrings` — `sidebar.group.menu.*` strings (en/ja).
- Notes:
  - Sidebar selection highlight is per-row and derived from the entry snapshot, not stored: the focused panel of the selected workspace renders solid blue and its same-workspace siblings render a lighter wash (`CasperSidebarPanelRow.Highlight`, commit `c3399b3d9`). An earlier group-level "selected group" tint on `CasperWorkspaceGroupSection` was removed as too broad — it highlighted every session in the active session's repo group, not just the active workspace's panels.
  - Group close reuses the existing multi-close confirmation; only the undo bookkeeping is batched.
- Deletion condition:
  - Delete if upstream adds first-class sidebar group selection, group context menus, and batched group close/reopen.

#### ⌘W group-close mode + empty-window state (follow-up)

Two behaviors layered onto group selection.

- **⌘W closes the active group while in group-selected mode.** `TabManager.casperGroupSelectionActive` (plain var, no view observes it) is set true by `CasperSidebarNavigator.selectGroup` (after its `focusTab` call, so the mode wins) and cleared the moment the user moves on to a session. Clear hooks: `selectedTabId.didSet` (covers every selection change — sidebar row click, ⌘↑/↓ arrow-nav, palette select, `selectWorkspace`/`selectTab`); the AppDelegate global key handler for any keystroke other than ⌘1…9 / ⌘W (covers typing AND in-terminal command keys like ⌘C/⌘V/⌘F); `GhosttyTerminalView.mouseDown` (clicking into a session — fires only on real clicks, never during keyboard selectGroup); and `applicationWillResignActive` (switching away from the app). The `.closeTab` (⌘W) dispatch checks the flag and routes to `CasperSidebarNavigator.closeActiveGroup()` (→ `casperCloseWorkspaceGroup`) instead of `closeCurrentPanelWithConfirmation()`.
- **Closing the last workspace empties the window** (empty sidebar + blank editor) instead of closing it. Centralised behind `TabManager.casperAllowsEmptyWindow` (== `CasperBuildEnvironment.isBranded`). Gated edits: `closeWorkspace` guard now `casperAllowsEmptyWindow || tabs.count > 1` and sets `selectedTabId = nil` when `tabs` empties; `closeWorkspaceIfRunningProcess` routes the last-workspace case to `closeWorkspace` (not `window.performClose`) and reports `willCloseWindow = false`; `closeWorkspacesPlan` (multi-close dialog) suppresses the "Close window?" wording; the child-exit path (`closePanelAfterChildExited`) and `detachWorkspace` (leaves the source window empty, `selectedTabId = nil`) do the same; ContentView's onAppear startup-recovery skips the `addWorkspace()` refill; the two AppleScript close handlers (`AppleScriptSupport.swift`) also honor it. The app already renders an empty `tabs`/nil selection safely (no crashes — sidebar/editor/title/socket are all nil-guarded). New sessions come from ⌘T / the always-visible titlebar new-workspace button / command palette. This also fixes the earlier "Close All on a whole-window group orphaned the ⌘⇧T entry" edge, since the window no longer closes. NOT changed: session restore still opens one fresh workspace on cold launch (a safety net for empty/corrupt restores), so an empty window does not persist across a relaunch.
- Deletion condition: delete with the group-selection feature; restore the `tabs.count > 1` invariant and `window.performClose` last-workspace behavior (drop `casperAllowsEmptyWindow`) if upstream doesn't adopt an empty-window state.

### Sidebar "Fork Session" context-menu action

> **RETIRED (2026-07 merge): the argv builder.** Upstream shipped its own `AgentResumeCommandBuilder.forkShellCommand` covering a superset of kinds (claude, codex, claudeTeams, codexTeams, opencode/omo), and `AgentLaunchSanitizer.preservedCodexForkArguments` now strips a leading `fork <id>` — the exact bug Casper's `codexSessionArguments` existed to fix. Casper's duplicate builder was deleted; `CasperForkSession.swift` (the sidebar entry point) still calls `forkShellCommand` and compiles unchanged against upstream's signature. Only the Casper-only UI surface below remains.

Adds a **Fork Session** item to the session-row right-click menu. Forking branches a live `claude`/`codex` agent into a brand-new workspace: the new terminal replays the original session's history under a *new* session id (`claude --resume <id> --fork-session` / `codex fork <id>`), leaving the original untouched. Only claude and codex are forkable today; the item is hidden for plain terminals and non-forkable agents.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperForkSession.swift` (new) — `forkableKind(for:panelId:)` is the cheap, render-time visibility gate (derives the kind from the panel's live `agentPIDKeysByPanelId` PID keys — `"claude_code"` / `"codex.*"` — with no disk I/O, then verifies the agent PID is alive via `kill(pid, 0)` so a SIGKILL'd agent's key, which lingers until the 30s stale-PID sweep, doesn't keep showing the item). `forkSession(tabManager:workspaceId:panelId:fallbackCwd:)` runs lazily on click: resolves the authoritative session via `RestorableAgentSessionIndex.load().snapshot(…)` (disk read, same as the panel-close path), builds the command with `AgentResumeCommandBuilder.forkShellCommand`, and opens a new workspace via `addWorkspace(workingDirectory:initialTerminalInput:)`. Shows an alert when no resumable session is found.
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/RestorableAgentSession.swift` — **no longer patched.** Upstream now owns `AgentResumeCommandBuilder.forkShellCommand` (see the retirement note below).
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `CasperSidebarRowActions` gained `canForkAgent` + `onForkSession`; `CasperSidebarPanelRow.contextMenuItems` gained the gated "Fork Session" button.
  - `Sources/ContentView.swift` — `casperSidebarRowActions(for:workspaceLookup:)` computes `canFork` (via `CasperForkSession.forkableKind`) and wires `onForkSession`.
  - `Resources/Localizable.xcstrings` — `sidebar.session.menu.fork`, `casper.fork.unavailable.title`, `casper.fork.unavailable.message` (en/ja).
- Notes:
  - `forkableKind` runs on every sidebar render, so it stays disk-free; only after matching a forkable key does it do a single `kill(pid, 0)` liveness probe. The disk-backed session lookup is deferred to the click handler.
  - `codex fork` is a recent subcommand — on an older `codex` the new terminal errors visibly (the same CLI-version dependency `codex resume` already carries).
- Deletion condition: delete if upstream adds first-class session forking from the sidebar (retire `forkShellCommand`/`forkArguments`/`codexSessionArguments`, restore the inline `resumeArguments` codex case, drop the two `CasperSidebarRowActions` fields, and remove `CasperForkSession.swift`).

### Sidebar session archive

Adds a collapsible **Archive** section at the bottom of the compact sidebar. Right-clicking a session row **or** a terminal panel offers "Archive Session"; that one session drops out of its repo group into the Archive. Selecting an archived session only *displays* it (it stays listed in Archive). It returns to its active repo folder only when the user **submits** work into it — a plain-Return command/agent-message in its terminal, a Feed reply, or the explicit "Move to Active Sessions" menu item. A terminal Return only counts as a submit when the user *typed into the session after archiving it* (composing keystrokes "arm" the panel) — a bare Enter that dismisses a pager/TUI prompt does not silently drain the archive. Archiving is **per-session (per-panel)**: "archive" is a sidebar-row presentation concept, not a workspace-detachment one — the panel stays in its workspace's bonsplit tree, only its sidebar row relocates. So a multi-panel workspace can have one session archived and the rest active, and shows rows in both the active groups and the Archive. Multi-session workspaces additionally offer "Archive Workspace" (archive every session in the workspace at once); single-session workspaces don't, since "Archive Session" already covers it.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperArchiveStore.swift` (new) — `CasperArchiveStore` (`ObservableObject` singleton; `@Published archivedPanelIds: Set<UUID>` + a UserDefaults-backed `isCollapsed`). `hasArchivedSessions` is the cheap hot-path gate (single bool read on every keystroke when nothing is archived). `noteTypedInput(panelId:)` arms a panel (typed input since archiving); `noteUserSubmit(panelId:origin:requireTypedInput:)` unarchives only if archived **and** armed (Feed passes `requireTypedInput: false`); `archivePanels(_:)` is the bulk "Archive Workspace" insert; `pruneMissing(livePanelIds:)` keeps the set aligned with live panels, and `pruneMissingAcrossMainWindows(origin:including:)` unions live panel ids across **all** `AppDelegate.mainWindowContexts` plus the caller's own TabManager (the store is app-global; pruning against one window's panels would wipe the other windows' archived sessions, and during restore the caller's window isn't registered in `mainWindowContexts` yet). All mutations emit `casper.archive.*` debug-log events tagged with a `CasperArchiveOrigin` (String-backed enum). `CasperArchiveSubmitDetector.isSubmitReturn(_:)` classifies a key event as a submit (plain Return/keypad-Enter; Shift/Option+Return are newline gestures and excluded); `isComposingKeystroke(_:)` classifies arming keystrokes (excludes Cmd/Ctrl chords, `.function` navigation keys, Escape). `CasperArchiveSection` is the collapsible bottom section view (archivebox header + baseline-aligned count, reuses the compact row builder).
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `CasperSidebarPanelEntry` gained `isArchived` (per-panel) and `isMultiPanelWorkspace` (both in `==`, stamped by `CasperSidebarPanelEntryBuilder.entries(…, archivedPanelIds:)`); `CasperSidebarRowActions` gained `onToggleArchive` + `onArchiveWorkspace`; `CasperSidebarPanelRow.contextMenuItems` gained the Archive/Move-to-Active button (label flips on `entry.isArchived`) plus the multi-session "Archive Workspace" button (gated on `entry.isMultiPanelWorkspace` — a value read, so no per-render bonsplit walk).
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/ContentView.swift` — `VerticalTabsSidebar` observes `CasperArchiveStore.shared`; `workspaceRows` partitions entries into `activePanelEntries` (→ repo groups) and `archivedPanelEntries` (→ `CasperArchiveSection` at the bottom, hidden when empty), and wires `onToggleArchive`/`onArchiveWorkspace` (the latter from the workspace's terminal panel ids). The per-row compact block was extracted into a shared `casperCompactPanelRow(entry:ownsWorkspaceAnchor:workspacesById:)` helper so the active groups and the Archive section render identical rows. A `pruneMissingAcrossMainWindows(origin: .tabsChange, including: tabManager)` call rides the existing `onChange(of: tabs.map(\.id))` handler; the sidebar's "Archive Workspace" action delegates to `PanelTabActions.archiveWorkspace(workspaceId:)`.
  - `Sources/GhosttyTerminalView.swift` — submit-or-arm hook in `keyDown`, placed after the `handleKeyboardCopyModeIfNeeded` consumption check: behind the `hasArchivedSessions` gate, `isSubmitReturn` → `noteUserSubmit(panelId:)`, else `isComposingKeystroke` → `noteTypedInput(panelId:)` (copy-mode-consumed j/k/h/l navigation never reaches the shell and must not arm; Cmd-chorded keys that bypass copy mode still count). The `paste`/`pasteAsPlainText` actions call `casperArmArchivedSessionForPaste()` (pasted text bypasses `keyDown` via Ghostty's binding action). Zero hot-path cost when nothing is archived (short-circuit bool). Known gaps by design: CLI/socket `surface.send_text`/`send_key`, AppleScript, drag-drop, and dictation direct-commit input neither arm nor submit — automation should not drain the archive.
  - `Sources/Feed/FeedCoordinator.swift` — `sendTextToWorkstream` calls `noteUserSubmit(panelId:)` on the resolved surface id (a Feed reply is a submit).
  - `Sources/Panels/PanelCloseTabContextMenu.swift` — `PanelTabActions` gained `archiveAvailable`/`isSessionArchived`/`toggleSessionArchive` + `canArchiveWorkspace`/`archiveWorkspace`; both the AppKit (`PanelTabActionMenuController`) and SwiftUI (`PanelTabActionsContextMenu`) panel right-click menus gained the gated Archive/Move-to-Active + Archive-Workspace items.
  - `Sources/SessionPersistence.swift` — `SessionPanelSnapshot.archived: Bool?` (optional → old session files decode as nil).
  - `Sources/Workspace.swift` — `sessionPanelSnapshot(…)` writes `archived: CasperArchiveStore.shared.isArchived(panelId) ? true : nil`; `applySessionPanelMetadata` re-registers the flag under the freshly-minted panel id on restore.
  - `Sources/Workspace+PanelLifecycle.swift` — `discardClosedPanelLifecycleState` (the single per-panel teardown chokepoint) calls `CasperArchiveStore.shared.unarchive(panelId)`, so closing an archived split-panel (workspace survives) can't leave a stale id that keeps `hasArchivedSessions` armed.
  - `Sources/TabManager.swift` — `restoreSessionSnapshot` calls `pruneMissingAcrossMainWindows(origin: .restore, including: self)` after `tabs` is live (the restored sessions were re-archived under their new panel ids during the restore loop; this drops the stale pre-restore ids without wiping other windows' registrations during sequential multi-window restore — `including: self` because the restoring window registers in `mainWindowContexts` only after restore). Panel UUIDs are regenerated on restore, so the live set can't be persisted by id directly.
  - `Sources/AppDelegate.swift` — `sessionAutosaveFingerprint` hashes `CasperArchiveStore.shared.archivedPanelIds`, so archiving/unarchiving alone dirties the autosave fingerprint (otherwise the flags only reach disk when unrelated state changes, and are lost on a non-graceful exit).
  - `cmuxTests/CasperArchiveStoreTests.swift` (new) — behavior tests for archive membership, the typed-input arming rule, prune semantics, and the submit/composing keystroke classifiers (registered in `project.pbxproj` under the cmuxTests target).
  - `Resources/Localizable.xcstrings` — `sidebar.session.menu.archive`, `sidebar.session.menu.unarchive`, `sidebar.session.menu.archiveWorkspace`, `sidebar.archive.header` (en/ja).
  - `cmux.xcodeproj/project.pbxproj` — registers `CasperArchiveStore.swift`.
- Notes:
  - Cross-restart durability rides the per-panel session snapshot, not UserDefaults, because panel UUIDs are freshly minted on every restore. Only the section-collapsed bool (stable identity) persists via UserDefaults.
  - Selecting an archived session deliberately does **not** unarchive — only a submit does. This is why the trigger lives at the Return keystroke / Feed-send / explicit-menu layer, not at the selection/`focusTab` layer.
- Deletion condition: delete if upstream adds a first-class sidebar session archive. Retire `CasperArchiveStore.swift`, the `isArchived`/`onToggleArchive`/`onArchiveWorkspace` additions, the `archived` panel-snapshot field + its read/write, the `keyDown`/`FeedCoordinator`/panel-menu hooks, the `AppDelegate.sessionAutosaveFingerprint` archive hash, `cmuxTests/CasperArchiveStoreTests.swift`, and the `casperCompactPanelRow` extraction (fold back inline).

## Merge conflict notes

These upstream files are touched by fork patches and tend to drift upstream. Re-check each when running `git merge upstream/main`:

- `Sources/Workspace.swift`
  - The reopen-last-closed patch specifically was retired in the 2026-07 merge in favor of upstream's `ClosedItemHistoryStore`, but the file is still live: touched by patch 4 (`tabBarVisibility: .multipleTabs` in `BonsplitConfiguration`), the activity publisher, the `appendLog` compatibility seam, and the archive patch (`sessionPanelSnapshot(…)` writes `archived:`, `applySessionPanelMetadata` re-registers it on restore). Re-validate all of the above on the next upstream merge — do not assume this file is untouched.
- `Sources/KeyboardShortcutSettings.swift`, `Sources/KeyboardShortcutContext.swift`
  - Touched by the session-nav patch (4 new actions + `.nonBrowserPanel` context + `casperEventEditsTextInput`). If upstream adds arrow-key actions, re-check default-shortcut collisions.

- `Sources/ContentView.swift`
  - Heaviest conflict surface. Touched by patches 2 (sidebar reveal strips, header icon alignment animation, effective titlebar padding), the minimal-mode window-movable policy (one-line call inside the WindowAccessor refresh), the workspace grouping patch (`workspaceRows` now wraps rows in a per-group `ForEach`), the archive patch (`workspaceRows` partitions active/archived, extracts `casperCompactPanelRow`, appends `CasperArchiveSection`; `pruneMissing` on the tabs `onChange`), and the cleanup tail. If upstream refactors sidebar layout, hidden-sidebar gap handling, or titlebar padding math, expect non-trivial manual conflict resolution.
- `Sources/TabManager.swift`
  - Touched by the workspace grouping patch (`moveTabToTopForNotification` now bumps within the workspace's repo group). Stock cmux unconditionally bumps to global top of unpinned.
  - Also touched by the group-selection follow-up: the empty-window gates in `closeWorkspace` (`guard … || tabs.count > 1`, `selectedTabId = nil` on empty), `closeWorkspaceIfRunningProcess` (Casper branch → `closeWorkspace`), and `closePanelAfterChildExited`; plus the `casperGroupSelectionActive` clear at the top of `focusTab`. Re-check these if upstream reworks the workspace-close or focus paths.
  - Also touched by the archive patch — see the dedicated `Sources/TabManager.swift (archive)` note below (`pruneMissingAcrossMainWindows` after `tabs` is assigned).
- `Sources/AppDelegate.swift`
  - Touched by patch 2 (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept, `runSidebarRevealEdgeMouseDownLoop`), patch 3 (new-workspace context menu shortcut display), the restore-time agent warmup patch (two one-line `CasperStartupAgentWarmup.applyStartupWarmup` calls in `applySessionWindowSnapshot` and `createMainWindow`), the group-selection patches (gated ⌘1…9 dispatch → `CasperSidebarNavigator.selectGroup`), the group-selection follow-up (`.closeTab` ⌘W routes to `closeActiveGroup` in group mode; a non-Command keystroke clears `casperGroupSelectionActive` in the global key handler), and the archive patch (`sessionAutosaveFingerprint` hashes `CasperArchiveStore.shared.archivedPanelIds`).
- `Sources/BackgroundWorkspacePrimeCoordinator.swift`
  - Touched by the restore-time agent warmup patch (`Policy.maxConcurrentPrimes` cap + `withTaskGroup` parallel driver in `primePendingBackgroundWorkspaces`). If upstream rewrites the coordinator's pending-loop, re-validate the bounded-parallelism rewrite.
- `Sources/RestorableAgentSession.swift`
  - The fork patch specifically was retired in the 2026-07 merge (upstream's own `forkShellCommand` superseded it), but the file is still live: touched by the `freshLaunchShellCommand` + orphan-transcript resume fallback (small CASPER hunk, see above). Re-validate that hunk on the next upstream merge — do not assume this file is untouched.
- `Sources/WindowDecorationsController.swift`
  - Touched by the minimal-mode window-movable policy (one-line call to `CasperMinimalModeWindowMovable.apply` inside `apply(to:)`). Re-add if upstream rewrites the decorations apply path.
- `Sources/GhosttyTerminalView.swift`
  - Touched by patches 3 (rightMouseDown mouse-capture handling, menu wiring, removed legacy selectors), 4 (New Tab right-click item), 7 (fish `XDG_DATA_DIRS` injection), the group-selection follow-up (a one-line `casperGroupSelectionActive` clear in `mouseDown`), and the archive patch (a `keyDown` submit hook beside the existing `dismissNotificationOnDirectInteraction` call). High-traffic file — re-validate each region after upstream merges.
- `Sources/Panels/PanelCloseTabContextMenu.swift`
  - Touched by the archive patch (`PanelTabActions.archiveAvailable`/`isSessionArchived`/`toggleSessionArchive`/`canArchiveWorkspace`/`archiveWorkspace` + the gated Archive / Archive-Workspace items in both the AppKit and SwiftUI panel menus). Re-validate if upstream reworks the panel tab-bar context menu.
- `Sources/Feed/FeedCoordinator.swift`
  - Touched by the archive patch (one `noteUserSubmit(panelId:origin:requireTypedInput:)` call in `sendTextToWorkstream`). Re-validate if upstream reworks the Feed reply path.
- `Sources/SessionPersistence.swift`, `Sources/Workspace.swift`, `Sources/Workspace+PanelLifecycle.swift`
  - Touched by the archive patch (`SessionPanelSnapshot.archived: Bool?`, written in `Workspace.sessionPanelSnapshot` and re-registered on restore in `applySessionPanelMetadata`; `discardClosedPanelLifecycleState` unarchives on panel teardown). Re-validate if upstream changes the panel snapshot shape, panel-restore path, or panel-teardown path.
- `Sources/TabManager.swift` (archive)
  - `restoreSessionSnapshot` calls `CasperArchiveStore.shared.pruneMissing(livePanelIds:)` after `tabs` is assigned. Re-validate if upstream reworks session restore.
- `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift`
  - Touched by patch 2 (`hitTest()` pass-through bands for sidebar reveal). Hot path for typing latency — preserve the `isPointerEvent` guard and the interior-point early-reject.
- `Sources/Update/UpdateTitlebarAccessory.swift`, `Sources/Update/MinimalModeSidebarControls.swift`, `Sources/WindowChromeMetrics.swift`
  - Touched by patch 2 (trailing-aligned hidden controls, fullscreen breathing room, content-sized host).
- `Sources/FileExplorerSearchController.swift`, `Sources/SessionIndexStore.swift`
  - Touched by patch 6 (shared `RipgrepLocator`). Keep one locator instance; do not let either site reintroduce its own fallback list.
- `Sources/Panels/FilePreviewPanel.swift`, `Sources/FileExplorerView.swift`
  - Touched by patch 5 (.ts text-file fast-path, Finder-row icon substitution).
- `Sources/FileDropOverlayViewHitTesting.swift`
  - Touched by the debug-log gating patch (`logHitTestDecision` stale-pasteboard guard).
- `cmux.xcodeproj/project.pbxproj`
  - Touched by patches 3 (new PanelCloseTabContextMenu.swift entry, removed legacy files), 6 (ripgrep PBXShellScriptBuildPhase + Copy CLI), and the archive patch (registers `CasperArchiveStore.swift`). Conflicts here are mechanical but always require manual resolution.
- `Resources/Localizable.xcstrings`
  - Touched by patches 2, 3, 4 and the archive patch (`sidebar.session.menu.archive`/`unarchive`, `sidebar.archive.header`). xcstrings JSON merges poorly; expect to redo string additions if upstream touches the same strings.
- `.github/workflows/release.yml`, `.github/workflows/nightly.yml`, `.github/workflows/build-ghosttykit.yml`, `.github/workflows/test-depot.yml`, `.github/workflows/test-e2e.yml`
  - Touched by patches 1 and 6 (heyitaki/ghostty URLs, ripgrep fetch+cache).
- `.gitmodules`
  - Touched by patches 1 (ghostty.url) and 4 (vendor/bonsplit.url). Both point at heyitaki/* forks.
- `Sources/ContentView.swift` — heaviest surface (patches 2, 6, 7, 9, 10). Upstream's sidebar render pipeline (`SidebarWorkspaceRenderItem`, `SidebarDragState`) is now the base; Casper layers sort/filter/compact-row on top. Never reintroduce preference-key→@State writes (livelock class #2586/#5708).
- `Sources/AppDelegate.swift` — patches 2, 3, 8, 12.
- `Sources/Workspace.swift` — patch 4 (tabBarVisibility), activity publisher, appendLog seam.
- `Sources/GhosttyTerminalView.swift` — patches 3, 4, 11.
- `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift` — patch 2 pass-through bands; typing-latency hot path.
- `Sources/Update/UpdateTitlebarAccessory.swift` — patch 2 (reload button + hidden-controls gating).
- `Sources/FileExplorerSearchController.swift`, `Sources/SessionIndexStore.swift` — patches 5, 10. Keep ONE rg resolution mechanism (upstream resolver with bundle-first candidate).
- `Sources/FileExplorerView.swift` — patch 10 + the `isExplicitTextFile` shim call.
- `cmux.xcodeproj/project.pbxproj` — Casper file registrations + ripgrep phases; objectVersion 60.
- `Resources/Localizable.xcstrings` — fork keys; JSON merges poorly.
- `.github/workflows/*`, `scripts/ensure-ghosttykit.sh`, `.gitmodules` — patch 1 (heyitaki URLs + flavor tags).
- `.github/swift-file-length-budget.tsv` — fork-grown files carry bumped budgets; upstream will not have these numbers.

## Retired fork patches

Obviated by the 2026-06-09 upstream merge (~1,830 commits):

- **File preview `.ts` routing** — upstream `knownTextResolutionBeforeMedia` (sniffs MPEG-TS byte patterns) supersedes the fork's text-extension fast path. Only the `isExplicitTextFile` shim remains for Finder-row icons.
- **Fish shell integration (`vendor_conf.d/cmux-shell-integration.fish`)** — upstream shipped `Resources/shell-integration/fish/config.fish` with per-surface CLI shims + a `claude` fish function (functions beat PATH; no re-prepend trick needed). The wrapper itself was renamed `cmux-claude-wrapper` upstream.
- **Workspace sidebar grouping by repo path (old `CasperWorkspaceGroupSection`-wrapped-VStack render path)** — the 2026-06 merge temporarily dropped per-panel rows and repo-path grouping in favor of upstream's user-defined WorkspaceGroups. The feature was restored in patch #7 above using a flat `CasperSidebarRenderPlan` + `LazyVStack` approach. `CasperWorkspaceGroupResolver`, `CasperWorkspaceGroups.swift`, and the new `CasperSidebarRenderPlan.swift` are all active fork files.
- **`CasperBoundedAsyncWorkPool` git-probe driver in TabManager** — upstream's `WorkspaceGitMetadataProbeLimiter` actor + directory-coalesced snapshot requests supersede it. The pool type remains for the warmup coordinator.
- **Cheap/heavy session-autosave fingerprint split** — upstream's `ProcessDetectedResumeIndexes` has no cheap path; dropped.
- **`WorkspaceSidebarMetadataStore` sub-store** — upstream's per-item snapshot architecture + event-driven `SharedLiveAgentIndex` address the original re-render concern; Workspace reverted to upstream's direct `@Published` layout.
- **Traffic-light debug offsets in WindowDecorationsController** — upstream stopped repositioning native titlebar buttons entirely.
- **`testNavigationFlashUsesGrayAccent`** — upstream unified all attention-flash styles onto the notification ring accent.
- **`collectAgentPIDsByWorkspace` single-pass scan in TerminalController** — upstream inlined equivalent logic in `socketListenerDidStart`.
