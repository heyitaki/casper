# Casper Fork Changes (heyitaki/cmux)

`heyitaki/cmux` is a fork of `manaflow-ai/cmux`. We carry these local patches indefinitely; do not assume any will be upstreamed. The point of this doc is to make `git merge upstream/main` cheap by giving the merger a map of where fork-only hunks live, why they exist, and what would obviate them.

See `CLAUDE.md` → "Upstream merge strategy (Casper fork)" for the discipline. This file is the per-patch register that the discipline points at.

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

## Merge conflict notes

These upstream files are touched by fork patches and tend to drift upstream. Re-check each one when running `git merge upstream/main`:

- `Sources/ContentView.swift`
  - Heaviest conflict surface. Touched by patches 2 (sidebar reveal strips, header icon alignment animation, effective titlebar padding) and the cleanup tail. If upstream refactors sidebar layout, hidden-sidebar gap handling, or titlebar padding math, expect non-trivial manual conflict resolution.
- `Sources/AppDelegate.swift`
  - Touched by patch 2 (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept, `runSidebarRevealEdgeMouseDownLoop`) and patch 3 (new-workspace context menu shortcut display).
- `Sources/GhosttyTerminalView.swift`
  - Touched by patches 3 (rightMouseDown mouse-capture handling, menu wiring, removed legacy selectors), 4 (New Tab right-click item), and 7 (fish `XDG_DATA_DIRS` injection). High-traffic file — re-validate each region after upstream merges.
- `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift`
  - Touched by patch 2 (`hitTest()` pass-through bands for sidebar reveal). Hot path for typing latency — preserve the `isPointerEvent` guard and the interior-point early-reject.
- `Sources/Update/UpdateTitlebarAccessory.swift`, `Sources/Update/MinimalModeSidebarControls.swift`, `Sources/WindowChromeMetrics.swift`
  - Touched by patch 2 (trailing-aligned hidden controls, fullscreen breathing room, content-sized host).
- `Sources/FileExplorerSearchController.swift`, `Sources/SessionIndexStore.swift`
  - Touched by patch 6 (shared `RipgrepLocator`). Keep one locator instance; do not let either site reintroduce its own fallback list.
- `Sources/Panels/FilePreviewPanel.swift`, `Sources/FileExplorerView.swift`
  - Touched by patch 5 (.ts text-file fast-path, Finder-row icon substitution).
- `GhosttyTabs.xcodeproj/project.pbxproj`
  - Touched by patches 3 (new PanelCloseTabContextMenu.swift entry, removed legacy files) and 6 (ripgrep PBXShellScriptBuildPhase + Copy CLI). Conflicts here are mechanical but always require manual resolution.
- `Resources/Localizable.xcstrings`
  - Touched by patches 2, 3, 4. xcstrings JSON merges poorly; expect to redo string additions if upstream touches the same strings.
- `.github/workflows/release.yml`, `.github/workflows/nightly.yml`, `.github/workflows/build-ghosttykit.yml`, `.github/workflows/test-depot.yml`, `.github/workflows/test-e2e.yml`
  - Touched by patches 1 and 6 (heyitaki/ghostty URLs, ripgrep fetch+cache).
- `.gitmodules`
  - Touched by patches 1 (ghostty.url) and 4 (vendor/bonsplit.url). Both point at heyitaki/* forks.

## Upstreamed fork changes

None yet — heyitaki/cmux has not landed any patch upstream into manaflow-ai/cmux. When the first one merges upstream, list it here with the original heyitaki SHA + the upstream commit that obviated it.
