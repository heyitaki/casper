# Casper Fork Changes (heyitaki/cmux)

`heyitaki/cmux` is a fork of `manaflow-ai/cmux`. We carry these local patches indefinitely; do not assume any will be upstreamed. The point of this doc is to make `git merge upstream/main` cheap by giving the merger a map of where fork-only hunks live, why they exist, and what would obviate them.

See `CLAUDE.md` → "Upstream merge strategy (Casper fork)" for the discipline. This file is the per-patch register that the discipline points at.

## Current merge debt

As of 2026-05-12, `heyitaki/cmux:main` is **caught up** with `manaflow-ai/cmux:main` via the latest `git merge upstream/main` (84 upstream commits merged, including the 64-commit backlog plus newer traffic).

Casper-only files now live under `Sources/Casper/Sidebar/` (`SidebarRevealStrip.swift`, `AppDelegate+SidebarRevealEdgeMouseHandler.swift`, `WindowHostView+SidebarRevealPassThrough.swift`), so the fork-vs-upstream surface in `Sources/ContentView.swift` and `Sources/AppDelegate.swift` is a handful of wiring lines plus `// CASPER:` comments.

**Hot paths to preserve during future conflict resolution.** `TerminalWindowPortal.hitTest()` and `BrowserWindowPortal.hitTest()` are touched on both sides and are typing-latency-critical (see `CLAUDE.md` → "Pitfalls"). Keep the `isPointerEvent` guard and any interior-point early-reject — these must not regress during the merge.

## Fork update checklist

1) Land the change on `main` (or via PR against `heyitaki/cmux`).
2) Add or update the section in this file describing what was touched and why.
3) If the change modifies any upstream cmux file, add a `// CASPER: <reason>; delete if upstream adds <X>` comment on the modified hunk so the next merger can grep for it.
4) Add the touched upstream files to "Merge conflict notes" below if they're not already listed.

## Current fork patches

### 1) Casper fork infrastructure

- Commits:
  - `f94a94b7` (docs: Add Casper fork upstream merge strategy)
  - `fcf1f44a` (ghostty: repoint submodule and release URLs at heyitaki/ghostty)
  - `ebceb13b` (ghostty: bump pin to debounce pty resize)
- Files:
  - `CLAUDE.md` (upstream merge strategy section)
  - `CONTRIBUTING.md`, `docs/ghostty-fork.md` (note heyitaki remote layout)
  - `.gitmodules` (ghostty.url → heyitaki/ghostty)
  - `.github/workflows/build-ghosttykit.yml`, `test-depot.yml`, `test-e2e.yml`
  - `scripts/ensure-ghosttykit.sh`, `scripts/download-prebuilt-ghosttykit.sh`
  - `ghostty` submodule pin
- Summary:
  - Points the ghostty submodule and xcframework release URLs at `heyitaki/ghostty` so cloning the fork doesn't require write access to `manaflow-ai/ghostty`.
  - The `Sync upstream` workflow on heyitaki/ghostty keeps that fork aligned with manaflow-ai/ghostty automatically; cmux's xcframework release token (`GHOSTTY_RELEASE_TOKEN`) must grant write to heyitaki/ghostty.
  - The bumped ghostty pin (`c6302d022`) carries cmux fork patches #10–#12 from `docs/ghostty-fork.md` (pty resize debounce, per-RunStep DEVELOPER_DIR helper, lazy iOS xcframework slices). The pin currently lives on local branch `cmux-prompt-flicker-pty-coalesce` and has not yet reached `manaflow-ai/ghostty:main`.
- Deletion condition:
  - Cannot be upstreamed by nature — it's the heyitaki ↔ manaflow boundary. Stays until heyitaki/cmux retires.

### 2) Minimal-mode sidebar and reveal strips

- Commits:
  - `2c003bd2` (Add leading-edge sidebar reveal strip and minimal-mode polish)
  - `de343cbc` (sidebar: Mirror reveal strip and resize edge to right sidebar)
  - `754e7246` (sidebar: Add fullscreen breathing room and trailing-aligned hidden controls)
  - `573322fa` (sidebar: Drop dead AppKit click target and leadingInset fallback hit-tests)
  - `2e04f180` (sidebar: Replace dev build banner with inline Development label)
- Files (upstream files modified — primary conflict surface):
  - `Sources/ContentView.swift` (~500+ inserted lines across these commits; biggest single conflict risk)
  - `Sources/AppDelegate.swift` (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept)
  - `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift` (`hitTest()` pass-through bands)
  - `Sources/Update/UpdateTitlebarAccessory.swift`, `Sources/Update/MinimalModeSidebarControls.swift`, `Sources/WindowChromeMetrics.swift`, `Sources/WindowDecorationsController.swift`, `Sources/WindowDragHandleView.swift`
  - `Sources/App/WorkspaceRuntimeSettings.swift` (default to minimal presentation)
  - `Sources/cmuxApp.swift` (removed dev-banner toggle)
  - `Resources/Localizable.xcstrings` (new sidebar reveal / hidden controls strings)
  - `cmuxTests/AppDelegateShortcutRoutingTests.swift` (sidebar reveal routing + edge-anchored window resize math)
- Summary:
  - Workspace defaults to minimal presentation mode; the hidden-sidebar gap is replaced with a 5pt SwiftUI reveal strip on each edge (click expands sidebar, drag resizes window).
  - `cmux_sendEvent` captures the click before AppKit's resize tracking starts. Window portals pass-through the same band so SwiftUI receives hovers/clicks (predicate centralized in `SidebarRevealStripMetrics.shouldPassThrough` / `SidebarRevealEdgeGeometry`).
  - Sidebar header icon cluster animates leading↔trailing alignment between fullscreen and windowed; pinned traffic-lights in minimal mode.
  - Cleanup commit removes the now-unused AppKit click target and stale leadingInset fallback hit-tests (registry + SwiftUI proxy cover all paths).
  - Inline "Development" label replaces the loud full-width red `THIS IS A DEV BUILD` banner.
- Deletion condition:
  - Delete the reveal-strip mouse-down intercept + pass-through predicate when upstream cmux adds equivalent edge-reveal affordances.
  - Delete the default-to-minimal-mode change if upstream adopts the same default (or move it behind `CasperConfig.defaultsToMinimalMode` when an upstream config seam appears).
  - Delete the inline Development label patch if upstream changes the dev-build affordance.
- Refactor candidate (high priority): the SwiftUI reveal-strip view, `SidebarRevealEdgeGeometry`, `SidebarRevealStripMetrics.shouldPassThrough`, and `runSidebarRevealEdgeMouseDownLoop` are net-new code currently living inside `ContentView.swift` / `AppDelegate.swift`. Moving them into a `Sources/Casper/Sidebar/` group would shrink the ContentView diff from ~500 lines to a handful of wiring lines.

### 3) Panel right-click context menu unification

- Commits:
  - `1afc64ab` (panels: Unify right-click tab actions and remove legacy menu code)
  - `23d16631` (sidebar: Show shortcuts in new-workspace right-click menu)
  - `0e32bb71` (terminal: Show context menu on right-click even when app captures mouse)
- Files added (new, no conflict):
  - `Sources/Panels/PanelCloseTabContextMenu.swift` (hosts `PanelTabActions`, `PanelTabActionMenuController`, and the SwiftUI/AppKit modifiers)
- Files (upstream files modified):
  - `Sources/GhosttyTerminalView.swift` (rightMouseDown forwarding under mouse capture; menu wiring; removed legacy selectors)
  - `Sources/CmuxWebView.swift`, `Sources/Panels/BrowserPanel.swift`, `Sources/Panels/MarkdownPanelView.swift`, `Sources/Panels/FilePreviewPanel.swift`, `Sources/Panels/FilePreviewTextEditor.swift`, `Sources/Panels/FilePreviewMagnifyingPDFView.swift` (route through shared controller)
  - `Sources/AppDelegate.swift`, `Sources/CmuxConfig.swift`, `Sources/CmuxSurfaceTabBarBuiltInAction.swift` (shortcut display in new-workspace right-click menu)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (register new file, drop deleted)
- Files removed (cleanup of pre-existing per-panel duplicates):
  - `Sources/CmuxWebView+CloseTab.swift`, `Sources/CmuxWebView+MoveTabToNewWorkspace.swift`, `Sources/BrowserPanel+CloseTab.swift`, `Sources/BrowserPanel+MoveTabToNewWorkspace.swift`, `Sources/GhosttyNSView+MoveTabToNewWorkspace.swift`
- Summary:
  - Single `PanelCloseTabContextMenu.swift` drives right-click Split/New Tab/Close Tab/Move Tab across terminal, browser, markdown, and file-preview panels.
  - Right-click in a terminal with mouse-capture enabled (vim `set mouse=a`, tmux, fullscreen TUIs) now forwards PRESS+RELEASE to the PTY and still presents the cmux context menu (super.rightMouseDown after the synthesized RELEASE).
  - New-workspace right-click items now display the user's bound keyboard shortcuts (cmux.json first, built-in mapping fallback) via `CmuxResolvedConfigAction.menuShortcut`.
- Deletion condition:
  - Mostly fork-internal refactoring; the new file is purely additive. The upstream-file diffs that remain are: rightMouseDown mouse-capture handling (delete when upstream adds equivalent), `menuShortcut` plumbing (delete when upstream adds shortcuts to context menu items).

### 4) bonsplit `.auto` tab-bar visibility + heyitaki/bonsplit submodule

- Commit:
  - `d139fa7e` (Hide single-tab pane bars and add New Tab right-click)
- Files:
  - `.gitmodules` (`vendor/bonsplit.url` → `heyitaki/bonsplit`)
  - `vendor/bonsplit` submodule pin
  - `Sources/Workspace.swift` (uses new `.auto` case)
  - `Sources/GhosttyTerminalView.swift` (New Tab right-click item)
  - `Resources/Localizable.xcstrings` (new strings)
- Summary:
  - bonsplit vendored through heyitaki/bonsplit (daily upstream-sync workflow) so we can ship `BonsplitConfiguration.Appearance.TabBarVisibility.auto`, hiding the per-pane tab bar whenever a pane has only one tab.
  - Terminal pane context menu gets a "New Tab" item so users can still add tabs when no bar is visible.
- Deletion condition:
  - Once `.auto` lands in manaflow/bonsplit upstream and `manaflow-ai/cmux` uses it, this entire patch goes away except for the heyitaki/bonsplit submodule pointer (which stays as fork infra alongside heyitaki/ghostty).

### 5) File preview .ts routing (TypeScript vs MPEG-2 transport stream)

- Commits:
  - `bcb782d1` (test: Add failing regression test for .ts → video misroute)
  - `ad603c63` (file-preview: Route .ts to text editor instead of video player)
- Files:
  - `Sources/FileExplorerView.swift` (Finder-row icon substitution for source-code files)
  - `Sources/Panels/FilePreviewPanel.swift` (`FilePreviewKindResolver.isExplicitTextFile` fast-path consulted before system UTI media check; plist carve-out)
  - `cmuxTests/FilePreviewReviewFeedbackTests.swift` (regression test pair)
- Summary:
  - macOS maps `.ts` to `public.mpeg-2-transport-stream`, so `.ts` files were routing to the AVKit video player. Resolver consults an in-resolver text allow-list before the system UTI media check; binary plists still hit the binary-vs-text sniff branch to keep QuickLook routing.
- Deletion condition:
  - Small, low-controversy bug fix. A clean candidate for an opportunistic upstream PR; until then, keep.

### 6) Bundled universal ripgrep for Find pane

- Commit:
  - `306b8f45` (search: Bundle universal ripgrep so Find pane works without system rg)
- Files added (purely new, no conflict):
  - `scripts/ensure-ripgrep.sh`, `scripts/ripgrep-checksums.txt`
- Files (upstream files modified):
  - `Sources/FileExplorerSearchController.swift` (new `RipgrepLocator`; bundle-first, system-fallback, `$PATH`-scan order)
  - `Sources/SessionIndexStore.swift` (uses shared `RipgrepLocator`)
  - `scripts/setup.sh`, `scripts/reload.sh` (invoke `ensure-ripgrep.sh`)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (PBXShellScriptBuildPhase + Copy CLI phase entry for `Resources/bin/rg`)
  - `.github/workflows/release.yml`, `.github/workflows/nightly.yml` (fetch + cache rg; release verifies fat binary)
  - `.gitignore` (`Resources/bin/rg`, `Resources/bin/rg.version`)
- Summary:
  - Bundles ripgrep 15.1.0 universal binary at `Resources/bin/rg`; the locator uses `Bundle.main.resourceURL?.appendingPathComponent("bin/rg")` (not `Bundle.url(forResource:)` — that only sees `PBXResourcesBuildPhase` and returns nil for files copied via `PBXCopyFilesBuildPhase`).
  - Adds ~8 MB to the app but removes the hard dependency on a system `rg` install; the official cmux build does not ship one either.
- Deletion condition:
  - Delete when upstream cmux bundles rg or replaces the search backend.

### 7) Fish shell integration for Claude wrapper

- Commit:
  - `2fd4acfb` (shell-integration: Add fish vendor_conf.d for Claude wrapper)
- Files added (purely new, no conflict):
  - `Resources/shell-integration/fish/vendor_conf.d/cmux-shell-integration.fish`
- Files (upstream files modified):
  - `Sources/GhosttyTerminalView.swift` (injects integration dir into `XDG_DATA_DIRS` in TerminalSurface env setup)
- Summary:
  - fish parity for the existing zsh/bash Claude wrapper integration. The vendor_conf.d script prepends the bundled bin dir to PATH and installs a `claude` shell function pointing at the wrapper by absolute path. Re-prepends PATH on `fish_prompt` once (then unregisters) so `fish_add_path -g` in user config can't demote our bin dir.
  - Without this, fish users' session snapshot/restore was silently broken — the wrapper at `Resources/bin/claude` injects `--session-id`/`--settings` so lifecycle hooks fire back into cmux, and bypassing it left the hook sessions file empty.
- Deletion condition:
  - Delete when upstream cmux adds a fish shell integration.

### Minimal-mode window-movable policy

- Files (added):
  - `Sources/Casper/Window/CasperMinimalModeWindowMovable.swift`
- Files (upstream files modified):
  - `Sources/WindowDecorationsController.swift` (one-line call inside `apply(to:)` so presentation-mode toggles re-apply the policy)
  - `Sources/ContentView.swift` (one-line call inside the `WindowAccessor` refresh so initial setup and appearance-mutation re-runs don't strand `isMovable = true`)
- Summary:
  - Casper defaults to `minimal` presentation mode, which strips `customTitlebar` (and its `WindowDragHandleView` overlay) from the workspace top. The bonsplit tab strip then sits directly under AppKit's system titlebar drag region. With the upstream default of `window.isMovable = true`, AppKit's automatic titlebar drag would hijack tab drags whenever the deepest hit-test view defaulted to `mouseDownCanMoveWindow == true` (SwiftUI's generated NSViews inside the strip). This patch forces `window.isMovable = false` on the main workspace window while in minimal mode. Bonsplit's `TabBarBackgroundNSView.mouseDown` and `DragNSView.startWindowDrag`, plus `WindowDragHandleView`'s `withTemporaryWindowMovableEnabled`, all flip `isMovable = true` for the duration of `performDrag(with:)` and restore — so every legitimate window-drag path keeps working. Stock cmux (standard mode) is unaffected.
- Deletion condition:
  - Delete if upstream restores `customTitlebar`/`WindowDragHandleView` in minimal mode or otherwise blocks AppKit's auto-titlebar-drag for the bonsplit tab strip.

### Workspace sidebar grouping by repo path

- Files (added):
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift`
- Files (upstream files modified):
  - `Sources/ContentView.swift` (replaces flat `ForEach` in `workspaceRows` with a grouped `ForEach`; headers only render when ≥2 groups)
  - `Sources/TabManager.swift` (`moveTabToTopForNotification` bumps to the top of the workspace's repo group instead of the global top)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (registers the new file)
- Summary:
  - When workspaces span multiple repos, the sidebar groups them under section headers named after the repo (basename of the directory containing `.git`). Headers are collapsible; per-group collapse state is persisted to `UserDefaults` under `casperWorkspaceGroupCollapsedKeys`. Within a group, ordering matches the underlying `tabs` array; notification-driven auto-reorder still moves a workspace to the top, but only within its group, so a notification in repo B can't shove repo A's workspaces down. Single-repo users see no visual change (headers hidden when there's only one group).
  - Group membership is resolved from **all** panel directories (`Workspace.panelDirectories.values`), not just the focused panel's `currentDirectory`. Panels resolved to the user's home directory are treated as neutral and ignored unless every panel is in `~` (new splits default to `~`, and a workspace already anchored to a real repo shouldn't reclassify just because the user opened more terminals). Among the non-neutral panels, the repo root with the highest count wins, with alphabetical tiebreak for stability. This prevents the workspace from bouncing between groups when the user shifts focus between two panels in different repos. Falls back to `currentDirectory` only before any OSC 7 has fired.
  - Repo root resolution walks up from each panel's directory looking for `.git`, with a process-lifetime cache keyed by the directory we resolved from. Cache is monotonic (entries never invalidate) which is fine since repo roots don't move within a session.
- Deletion condition:
  - Delete if upstream cmux adds first-class workspace grouping in the sidebar.

### Compact one-line sidebar workspace row

- Files (added):
  - `Sources/Casper/Sidebar/CasperCompactWorkspaceRow.swift`
  - `Sources/Casper/Sidebar/CasperAgentActivity.swift`
- Files (upstream files modified):
  - `Sources/ContentView.swift` (`TabItemView.body` — adds `isCasperCompact` gate that strips an agent activity glyph from the title, unbolds it, inserts the activity indicator on the right of the title row, hides all below-title sub-rows, and indents leading padding to align with the workspace-group folder icon; `VerticalTabsSidebar.workspaceRows` sorts workspaces by activity recency before passing to `CasperWorkspaceGroupResolver.groups`)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (registers the new files)
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
  - Activity timestamp for `working`/`needsInput` comes from `SidebarStatusEntry.timestamp` (set by cmux's CLI when the hook fires), promoted to `latestNotification.createdAt` if a newer notification exists in the `needsInput` branch. The `done` state additionally consults Claude Code's JSONL transcript (last real `user`/`assistant` message timestamp, skipping `/resume` metadata and `/compact` summaries — see `CasperClaudeActivityIO.parseLatestRealActivity`) so a workspace that's been idle but had real conversation still shows accurate recency. JSONL attribution is always per-session: hook records (`~/.cmuxterm/claude-hook-sessions.json`, written by SessionStart) for live launches, and `Workspace.restoredAgentSnapshotsByPanelId[*].sessionId` for workspaces that came back from session persistence. We deliberately do NOT fall back to "every JSONL under `~/.claude/projects/<encoded-cwd>/`" — that aggregated max(timestamp) across every sibling session in the cwd, pegging every workspace sharing a project root (e.g. all `~/code/pixie` tabs) to the most-recently-active sibling's time. Better to show no trailing time than a wildly misleading one.
  - The indicator uses two `TimelineView(.periodic(from:by:))` schedules — one at 30s for the relative-time text and one at `workingTickInterval` (0.45s) for the working-dots phase — both anchored to a shared static `timelineEpoch` so every row's ticks align to the same wall-clock instants (so SwiftUI can batch them into one layout pass). The body re-reads the activity each tick so the relative-time text stays fresh without subscribing to `Workspace.objectWillChange` from inside a row body (which would violate the workspace-list snapshot-boundary rule).
  - Workspace ordering: `workspaceRows` runs a stable sort over the filtered tab list before grouping (`CasperAgentActivity.compareActivityDesc`): pinned workspaces first, then most-recent activity first within each partition, with `.none` workspaces sinking to the bottom. Ties preserve original `tabManager` order so identical states don't jitter between renders.
- Deletion condition:
  - Delete if upstream cmux adds a first-class compact sidebar mode that drops auxiliary rows and shows last-activity inline.

### Restore-time agent workspace warmup (parallel)

- Files (added):
  - `Sources/Casper/CasperStartupAgentWarmup.swift`
  - `cmuxTests/CasperStartupAgentWarmupTests.swift`
- Files (upstream files modified):
  - `Sources/AppDelegate.swift` (two one-line hooks in `applySessionWindowSnapshot` and `createMainWindow`, gated on `CasperBuildEnvironment.isBranded`, calling `CasperStartupAgentWarmup.applyStartupWarmup`)
  - `Sources/BackgroundWorkspacePrimeCoordinator.swift` (sequential `for` over pending IDs replaced with a rolling `withTaskGroup` capped at `min(pending, Policy.maxConcurrentPrimes)`, where the cap is `activeProcessorCount` with thermal-state downshift)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (registers the new files)
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
  - `GhosttyTabs.xcodeproj/project.pbxproj` (registers the two new files)
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

### Sidebar session navigation, context menu, ordering + reopen-last-closed

Four related sidebar/session features.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperSidebarNavigator.swift` (new) — rebuilds the displayed sidebar order and moves focus for ⌘↑/↓ (next/prev session) and ⌘⇧↑/↓ (next/prev workspace).
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `groups(from:)` now sorts rows *within* each folder group strictly by per-session recency (de-clump: a workspace's split-panels are no longer forced adjacent); added `CasperSidebarRowActions` bundle + the row `.contextMenu` (Rename / Pin / Duplicate / Open cwd / Reveal / Copy path / Close).
  - `Sources/Casper/Sidebar/CasperAgentActivity.swift` — added `compareEntryActivityDesc` (entry-level recency comparator).
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/KeyboardShortcutSettings.swift` — 4 new actions (`nextSession`/`prevSession`/`nextSessionWorkspace`/`prevSessionWorkspace`, default ⌘↑/↓ + ⌘⇧↑/↓); generalized the `reopenClosedBrowserPanel` label to "Reopen Closed Session".
  - `Sources/KeyboardShortcutContext.swift` — `.nonBrowserPanel` context for the 4 nav actions; `casperEventEditsTextInput(_:)` guard so ⌘↑/↓ stays text-nav in editing fields.
  - `Sources/AppDelegate.swift` — 4 nav dispatch arms (guarded by the text-input check) → `CasperSidebarNavigator`; rerouted ⌘⇧T to `casperReopenLastClosedItem()`.
  - `Sources/ContentView.swift` — `VerticalTabsSidebar` builds `CasperSidebarRowActions` per row (`casperSidebarRowActions`/`casperSessionWorkingDirectory`), hoisted `let rowActions` to keep the row initializer type-checkable; rerouted the command-palette reopen to `casperReopenLastClosedItem()`.
  - `Sources/cmuxApp.swift` — File-menu "Reopen Closed Session" button → `casperReopenLastClosedItem()`.
  - `Sources/Workspace.swift` — added `panelSnapshot` to `ClosedBrowserPanelRestoreSnapshot`; generalized `stageClosedBrowserRestoreSnapshotIfNeeded` to capture ANY panel type (terminal/file-preview/markdown/browser); added internal seam `casperRestoreClosedPanel(from:inPane:)`.
  - `Sources/TabManager.swift` — unified `casperRecentlyClosedItems` stack + `CasperClosedItem` enum; `casperReopenLastClosedItem()` and helpers (panel 3-tier-best-effort restore via `createPanel`; whole-workspace restore via `sessionSnapshot`/`restoreSessionSnapshot` at original index, agents auto-resume); `closeWorkspace` capture hook before `teardownAllPanels()`; `wireClosedBrowserTracking` routes closes into the unified stack.
  - `GhosttyTabs.xcodeproj/project.pbxproj` — new `CasperSidebarNavigator.swift` build entry.
  - `Resources/Localizable.xcstrings` — new shortcut + context-menu strings (en/ja); updated reopen label.
  - `web/data/cmux-shortcuts.ts`, `web/data/cmux.schema.json` — the 4 new shortcut actions added to the public shortcuts reference + the `cmux.json` schema enum (shortcut policy requires both).
- Notes:
  - ⌘↑/↓ and ⌘⇧↑/↓ intentionally shadow Ghostty's jump-to-prompt inside a focused terminal (cmux's local monitor intercepts first). The text-input guard preserves ⌘↑/↓ as move-to-start/end inside editing fields.
  - The legacy browser-only path (`recentlyClosedBrowsers`, `reopenMostRecentlyClosedBrowserPanel`) is no longer reached by ⌘⇧T but left in place to minimize upstream churn; `reopenClosedBrowserPanel(_:in:)` is still used for the browser sub-case of the unified reopen.
- Deletion condition:
  - Delete if upstream adds first-class sidebar row keyboard nav, per-session row ordering/context menus, and a unified reopen-closed (panel + workspace) stack.

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

Adds a **Fork Session** item to the session-row right-click menu. Forking branches a live `claude`/`codex` agent into a brand-new workspace: the new terminal replays the original session's history under a *new* session id (`claude --resume <id> --fork-session` / `codex fork <id>`), leaving the original untouched. Only claude and codex are forkable today; the item is hidden for plain terminals and non-forkable agents.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperForkSession.swift` (new) — `forkableKind(for:panelId:)` is the cheap, render-time visibility gate (derives the kind from the panel's live `agentPIDKeysByPanelId` PID keys — `"claude_code"` / `"codex.*"` — with no disk I/O, then verifies the agent PID is alive via `kill(pid, 0)` so a SIGKILL'd agent's key, which lingers until the 30s stale-PID sweep, doesn't keep showing the item). `forkSession(tabManager:workspaceId:panelId:fallbackCwd:)` runs lazily on click: resolves the authoritative session via `RestorableAgentSessionIndex.load().snapshot(…)` (disk read, same as the panel-close path), builds the command with `AgentResumeCommandBuilder.forkShellCommand`, and opens a new workspace via `addWorkspace(workingDirectory:initialTerminalInput:)`. Shows an alert when no resumable session is found.
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/RestorableAgentSession.swift` — additive `AgentResumeCommandBuilder.forkShellCommand` + private `forkArguments`, plus a shared private `codexSessionArguments(subcommand:…)` that both `forkArguments` and the `resumeArguments` codex case route through (keeps resume/fork in lockstep, and peels a leading `fork <id>` so a `codex fork …`-launched session stays resumable AND forkable — the sanitizer otherwise hard-blocks a leading `fork`). Reuses the existing resume argv/env/cwd/launcher machinery (so `CLAUDE_CONFIG_DIR` auth selection and the `claudeTeams` launcher survive); claude reuses `resumeArguments` then appends `--fork-session`, codex shares the resume argv with the subcommand swapped to `fork`. The only behavior change to resume is the bugfix above.
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `CasperSidebarRowActions` gained `canForkAgent` + `onForkSession`; `CasperSidebarPanelRow.contextMenuItems` gained the gated "Fork Session" button.
  - `Sources/ContentView.swift` — `casperSidebarRowActions(for:workspaceLookup:)` computes `canFork` (via `CasperForkSession.forkableKind`) and wires `onForkSession`.
  - `Resources/Localizable.xcstrings` — `sidebar.session.menu.fork`, `casper.fork.unavailable.title`, `casper.fork.unavailable.message` (en/ja).
- Notes:
  - `forkableKind` runs on every sidebar render, so it stays disk-free; only after matching a forkable key does it do a single `kill(pid, 0)` liveness probe. The disk-backed session lookup is deferred to the click handler.
  - `codex fork` is a recent subcommand — on an older `codex` the new terminal errors visibly (the same CLI-version dependency `codex resume` already carries).
- Deletion condition: delete if upstream adds first-class session forking from the sidebar (retire `forkShellCommand`/`forkArguments`/`codexSessionArguments`, restore the inline `resumeArguments` codex case, drop the two `CasperSidebarRowActions` fields, and remove `CasperForkSession.swift`).

### Sidebar session archive

Adds a collapsible **Archive** section at the bottom of the compact sidebar. Right-clicking a session row **or** a terminal panel offers "Archive Session"; that one session drops out of its repo group into the Archive. Selecting an archived session only *displays* it (it stays listed in Archive). It returns to its active repo folder only when the user **submits** work into it — a plain-Return command/agent-message in its terminal, a Feed reply, or the explicit "Move to Active Sessions" menu item. Archiving is **per-session (per-panel)**: "archive" is a sidebar-row presentation concept, not a workspace-detachment one — the panel stays in its workspace's bonsplit tree, only its sidebar row relocates. So a multi-panel workspace can have one session archived and the rest active, and shows rows in both the active groups and the Archive. Multi-session workspaces additionally offer "Archive Workspace" (archive every session in the workspace at once); single-session workspaces don't, since "Archive Session" already covers it.

- Casper-only files:
  - `Sources/Casper/Sidebar/CasperArchiveStore.swift` (new) — `CasperArchiveStore` (`ObservableObject` singleton; `@Published archivedPanelIds: Set<UUID>` + a UserDefaults-backed `isCollapsed`). `hasArchivedSessions` is the cheap hot-path gate (single bool read on every Return keystroke when nothing is archived). `noteUserSubmit(panelId:)` unarchives only if archived; `archivePanels(_:)` is the bulk "Archive Workspace" insert; `pruneMissing(livePanelIds:)` keeps the set aligned with live panels. `CasperArchiveSubmitDetector.isSubmitReturn(_:)` classifies a key event as a submit (plain Return/keypad-Enter; Shift/Option+Return are newline gestures and excluded). `CasperArchiveSection` is the collapsible bottom section view (archivebox header + baseline-aligned count, reuses the compact row builder).
  - `Sources/Casper/Sidebar/CasperWorkspaceGroups.swift` — `CasperSidebarPanelEntry` gained `isArchived` (per-panel) and `isMultiPanelWorkspace` (both in `==`, stamped by `CasperSidebarPanelEntryBuilder.entries(…, archivedPanelIds:)`); `CasperSidebarRowActions` gained `onToggleArchive` + `onArchiveWorkspace`; `CasperSidebarPanelRow.contextMenuItems` gained the Archive/Move-to-Active button (label flips on `entry.isArchived`) plus the multi-session "Archive Workspace" button (gated on `entry.isMultiPanelWorkspace` — a value read, so no per-render bonsplit walk).
- Upstream files modified (all `// CASPER:`-marked):
  - `Sources/ContentView.swift` — `VerticalTabsSidebar` observes `CasperArchiveStore.shared`; `workspaceRows` partitions entries into `activePanelEntries` (→ repo groups) and `archivedPanelEntries` (→ `CasperArchiveSection` at the bottom, hidden when empty), and wires `onToggleArchive`/`onArchiveWorkspace` (the latter from the workspace's terminal panel ids). The per-row compact block was extracted into a shared `casperCompactPanelRow(entry:ownsWorkspaceAnchor:workspacesById:)` helper so the active groups and the Archive section render identical rows. A `pruneMissing(livePanelIds:)` call rides the existing `onChange(of: tabs.map(\.id))` handler.
  - `Sources/GhosttyTerminalView.swift` — one-line submit hook in `keyDown` after the existing `dismissNotificationOnDirectInteraction` call: `hasArchivedSessions && isSubmitReturn` → `noteUserSubmit(panelId: terminalSurface.id)`. Zero hot-path cost when nothing is archived (short-circuit bool).
  - `Sources/Feed/FeedCoordinator.swift` — `sendTextToWorkstream` calls `noteUserSubmit(panelId:)` on the resolved surface id (a Feed reply is a submit).
  - `Sources/Panels/PanelCloseTabContextMenu.swift` — `PanelTabActions` gained `archiveAvailable`/`isSessionArchived`/`toggleSessionArchive` + `canArchiveWorkspace`/`archiveWorkspace`; both the AppKit (`PanelTabActionMenuController`) and SwiftUI (`PanelTabActionsContextMenu`) panel right-click menus gained the gated Archive/Move-to-Active + Archive-Workspace items.
  - `Sources/SessionPersistence.swift` — `SessionPanelSnapshot.archived: Bool?` (optional → old session files decode as nil).
  - `Sources/Workspace.swift` — `sessionPanelSnapshot(…)` writes `archived: CasperArchiveStore.shared.isArchived(panelId) ? true : nil`; `applySessionPanelMetadata` re-registers the flag under the freshly-minted panel id on restore.
  - `Sources/Workspace+PanelLifecycle.swift` — `discardClosedPanelLifecycleState` (the single per-panel teardown chokepoint) calls `CasperArchiveStore.shared.unarchive(panelId)`, so closing an archived split-panel (workspace survives) can't leave a stale id that keeps `hasArchivedSessions` armed.
  - `Sources/TabManager.swift` — `restoreSessionSnapshot` calls `pruneMissing(livePanelIds:)` after `tabs` is live (the restored sessions were re-archived under their new panel ids during the restore loop; this drops the stale pre-restore ids). Panel UUIDs are regenerated on restore, so the live set can't be persisted by id directly.
  - `Resources/Localizable.xcstrings` — `sidebar.session.menu.archive`, `sidebar.session.menu.unarchive`, `sidebar.session.menu.archiveWorkspace`, `sidebar.archive.header` (en/ja).
  - `GhosttyTabs.xcodeproj/project.pbxproj` — registers `CasperArchiveStore.swift`.
- Notes:
  - Cross-restart durability rides the per-panel session snapshot, not UserDefaults, because panel UUIDs are freshly minted on every restore. Only the section-collapsed bool (stable identity) persists via UserDefaults.
  - Selecting an archived session deliberately does **not** unarchive — only a submit does. This is why the trigger lives at the Return keystroke / Feed-send / explicit-menu layer, not at the selection/`focusTab` layer.
- Deletion condition: delete if upstream adds a first-class sidebar session archive. Retire `CasperArchiveStore.swift`, the `isArchived`/`onToggleArchive`/`onArchiveWorkspace` additions, the `archived` panel-snapshot field + its read/write, the `keyDown`/`FeedCoordinator`/panel-menu hooks, and the `casperCompactPanelRow` extraction (fold back inline).

## Merge conflict notes

These upstream files are touched by fork patches and tend to drift upstream. Re-check each one when running `git merge upstream/main`:

- `Sources/Workspace.swift`
  - Touched by the reopen-last-closed patch (`ClosedBrowserPanelRestoreSnapshot.panelSnapshot` field, generalized `stageClosedBrowserRestoreSnapshotIfNeeded`, `casperRestoreClosedPanel` seam). Re-validate the close-staging path if upstream reworks browser-panel close capture.
- `Sources/KeyboardShortcutSettings.swift`, `Sources/KeyboardShortcutContext.swift`
  - Touched by the session-nav patch (4 new actions + `.nonBrowserPanel` context + `casperEventEditsTextInput`). If upstream adds arrow-key actions, re-check default-shortcut collisions.

- `Sources/ContentView.swift`
  - Heaviest conflict surface. Touched by patches 2 (sidebar reveal strips, header icon alignment animation, effective titlebar padding), the minimal-mode window-movable policy (one-line call inside the WindowAccessor refresh), the workspace grouping patch (`workspaceRows` now wraps rows in a per-group `ForEach`), the archive patch (`workspaceRows` partitions active/archived, extracts `casperCompactPanelRow`, appends `CasperArchiveSection`; `pruneMissing` on the tabs `onChange`), and the cleanup tail. If upstream refactors sidebar layout, hidden-sidebar gap handling, or titlebar padding math, expect non-trivial manual conflict resolution.
- `Sources/TabManager.swift`
  - Touched by the workspace grouping patch (`moveTabToTopForNotification` now bumps within the workspace's repo group). Stock cmux unconditionally bumps to global top of unpinned.
  - Also touched by the group-selection follow-up: the empty-window gates in `closeWorkspace` (`guard … || tabs.count > 1`, `selectedTabId = nil` on empty), `closeWorkspaceIfRunningProcess` (Casper branch → `closeWorkspace`), and `closePanelAfterChildExited`; plus the `casperGroupSelectionActive` clear at the top of `focusTab`. Re-check these if upstream reworks the workspace-close or focus paths.
  - Also touched by the archive patch — see the dedicated `Sources/TabManager.swift (archive)` note below (`pruneMissing(livePanelIds:)` after `tabs` is assigned).
- `Sources/AppDelegate.swift`
  - Touched by patch 2 (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept, `runSidebarRevealEdgeMouseDownLoop`), patch 3 (new-workspace context menu shortcut display), the restore-time agent warmup patch (two one-line `CasperStartupAgentWarmup.applyStartupWarmup` calls in `applySessionWindowSnapshot` and `createMainWindow`), the group-selection patches (gated ⌘1…9 dispatch → `CasperSidebarNavigator.selectGroup`), and the group-selection follow-up (`.closeTab` ⌘W routes to `closeActiveGroup` in group mode; a non-Command keystroke clears `casperGroupSelectionActive` in the global key handler).
- `Sources/BackgroundWorkspacePrimeCoordinator.swift`
  - Touched by the restore-time agent warmup patch (`Policy.maxConcurrentPrimes` cap + `withTaskGroup` parallel driver in `primePendingBackgroundWorkspaces`). If upstream rewrites the coordinator's pending-loop, re-validate the bounded-parallelism rewrite.
- `Sources/RestorableAgentSession.swift`
  - Touched by the "Fork Session" patch: additive `forkShellCommand`/`forkArguments`/`codexSessionArguments`, and the `resumeArguments` codex case now delegates to `codexSessionArguments` (one-line change). Re-validate the claude/codex argv shapes if upstream restructures `resumeArguments` or the resume/fork CLI flags change.
- `Sources/WindowDecorationsController.swift`
  - Touched by the minimal-mode window-movable policy (one-line call to `CasperMinimalModeWindowMovable.apply` inside `apply(to:)`). Re-add if upstream rewrites the decorations apply path.
- `Sources/GhosttyTerminalView.swift`
  - Touched by patches 3 (rightMouseDown mouse-capture handling, menu wiring, removed legacy selectors), 4 (New Tab right-click item), 7 (fish `XDG_DATA_DIRS` injection), the group-selection follow-up (a one-line `casperGroupSelectionActive` clear in `mouseDown`), and the archive patch (a `keyDown` submit hook beside the existing `dismissNotificationOnDirectInteraction` call). High-traffic file — re-validate each region after upstream merges.
- `Sources/Panels/PanelCloseTabContextMenu.swift`
  - Touched by the archive patch (`PanelTabActions.archiveAvailable`/`isSessionArchived`/`toggleSessionArchive`/`canArchiveWorkspace`/`archiveWorkspace` + the gated Archive / Archive-Workspace items in both the AppKit and SwiftUI panel menus). Re-validate if upstream reworks the panel tab-bar context menu.
- `Sources/Feed/FeedCoordinator.swift`
  - Touched by the archive patch (one `noteUserSubmit(panelId:)` call in `sendTextToWorkstream`). Re-validate if upstream reworks the Feed reply path.
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
- `GhosttyTabs.xcodeproj/project.pbxproj`
  - Touched by patches 3 (new PanelCloseTabContextMenu.swift entry, removed legacy files), 6 (ripgrep PBXShellScriptBuildPhase + Copy CLI), and the archive patch (registers `CasperArchiveStore.swift`). Conflicts here are mechanical but always require manual resolution.
- `Resources/Localizable.xcstrings`
  - Touched by patches 2, 3, 4 and the archive patch (`sidebar.session.menu.archive`/`unarchive`, `sidebar.archive.header`). xcstrings JSON merges poorly; expect to redo string additions if upstream touches the same strings.
- `.github/workflows/release.yml`, `.github/workflows/nightly.yml`, `.github/workflows/build-ghosttykit.yml`, `.github/workflows/test-depot.yml`, `.github/workflows/test-e2e.yml`
  - Touched by patches 1 and 6 (heyitaki/ghostty URLs, ripgrep fetch+cache).
- `.gitmodules`
  - Touched by patches 1 (ghostty.url) and 4 (vendor/bonsplit.url). Both point at heyitaki/* forks.

## Upstreamed fork changes

None yet — heyitaki/cmux has not landed any patch upstream into manaflow-ai/cmux. When the first one merges upstream, list it here with the original heyitaki SHA + the upstream commit that obviated it.
