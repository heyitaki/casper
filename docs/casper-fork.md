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

- Files: `Sources/FileDropOverlayViewHitTesting.swift`, `Sources/TerminalWindowPortal.swift` (stale-drag-pasteboard guards), `Sources/GhosttyTerminalView.swift` (`forceRefresh` skips healthy keystroke logging)
- Summary: prevents per-keystroke hitTest walks and log writes after any file drag; keeps diagnostics for real drags/anomalies.
- Deletion condition: delete if upstream rewrites the instrumentation.

### 12) Small CASPER hunks (grep `// CASPER:` for the authoritative list)

- `Sources/AppDelegate.swift` — `isModalOrSheetPresented` (gates alert key-equivalent scan per keystroke).
- `Sources/TerminalController.swift` — `shouldReplacePorts` guard on the ports `@Published` write.
- `Sources/VaultAgentProcessScanner.swift` — pid-keyed argv parse cache (`VaultAgentArgvCache`).
- `Sources/Workspace.swift` — `appendLog` compatibility seam (left from the sub-store retirement; fold into call sites when convenient).
- `CLI/cmux.swift` — Codex `prompt-submit` pushes the prompt as a soft sidebar title (`surface.set_title`).
- `Resources/bin/cmux-claude-wrapper` — no startup socket gate (hooks connect independently); shim self-detection also matches the renamed wrapper path.
- `Sources/RestorableAgentSession.swift` — `freshLaunchShellCommand` + orphan-transcript fallback for resume.

## Merge conflict notes

These upstream files are touched by fork patches and tend to drift upstream. Re-check each when running `git merge upstream/main`:

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
