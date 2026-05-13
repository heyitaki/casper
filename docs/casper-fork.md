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

### Find-sidebar grouped UI (flag-gated)

- Files (added):
  - `Sources/Casper/Search/CasperFindUIConfig.swift`
  - `Sources/Casper/Search/CasperFindPreviewSlice.swift`
  - `Sources/Casper/Search/CasperFindGroupedResults.swift`
  - `Sources/Casper/Search/CasperFindFileIcon.swift`
  - `Sources/Casper/Search/CasperFindResultsView.swift`
- Files (upstream files modified):
  - `Sources/FileExplorerView.swift` (sibling `CasperFindResultsView` overlaid on the legacy `searchScrollView`; gated branches in `updateSearchLayout`, `applySearchSnapshot`, `moveSearchSelection`, `openSelectedSearchResult`, and `ownsKeyboardFocus`; optional `onOpenFilePreviewAtLine` callback threaded into `FileExplorerPanelView` + `Coordinator`)
  - `Sources/RightSidebarPanelView.swift` (forwards optional `onOpenFilePreviewAtLine` to `FileExplorerPanelView` for both `.files` and `.find` modes)
  - `Sources/ContentView.swift` (wires the `RightSidebarPanelView.onOpenFilePreviewAtLine` closure to `openFilePreviewFromSidebar(filePath:scrollTarget:)`)
  - `Sources/Workspace.swift` (`openOrFocusFilePreviewSurface` gained optional `scrollTarget: CasperFilePreviewScrollTarget?` parameter that it assigns to `preview.casperPendingScrollTarget`)
  - `Sources/Panels/FilePreviewPanel.swift` (defines `CasperFilePreviewScrollTarget` and `@Published var casperPendingScrollTarget`)
  - `Sources/Casper/Editor/CasperPersistentSourceEditor.swift` (`CasperEditorAttachment` subscribes to `panel.$casperPendingScrollTarget` and calls `setCursorPositions(_:scrollToVisible:)` then clears the target)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (registers the new files)
- Summary:
  - Stock cmux renders Find results in a flat `NSTableView` with one row per hit, prefixed by `relativePath:lineNumber`. With many hits per file the list devolves into pages of repeated paths and the user can't tell at a glance which files matched most. This patch ships a VS Code-style grouped view: collapsible per-file headers with a system file icon, bold filename, smaller gray parent-directory path, and a hit-count badge; preview rows hide the line number, render the matched line via `CasperFindPreviewSlicer` (leading `…` when the match sits past the first ~12 chars), and highlight every occurrence of the query with an orange-tinted background range. The new view is a sibling overlay of `searchScrollView`; when the gate is on, the legacy table stays permanently hidden, and `applySearchSnapshot` feeds the Casper view alongside it so the snapshot pipeline (`FileSearchController`) needs no changes. Selection/Enter/Esc/up-down/double-click routing is delegated to the new view via gated branches in `FileExplorerContainerView`. Double-clicking a hit carries its 1-indexed `(line, column)` through `onOpenFilePreviewAtLine` → `openFilePreviewFromSidebar` → `openOrFocusFilePreviewSurface(scrollTarget:)`, which sets `FilePreviewPanel.casperPendingScrollTarget`; the persistent Casper source editor's Combine subscription consumes it and scrolls/positions the cursor at the match.
  - Enable with env `CMUX_CASPER_FIND_UI=1` or Info.plist key `CasperFindUIEnabled = YES`. Brand-name fallback turns it on for Casper builds and leaves stock cmux unchanged.
- Deletion condition:
  - Delete if upstream cmux ships a grouped Find-sidebar UI that replaces the flat `FileExplorerSearchResultsTableView`.

### Casper HMR daemon (PR 3 of 3 — InjectionLite removed)

- Files (added):
  - `Sources/Casper/HMR/CasperHMRConfig.swift`
  - `Sources/Casper/HMR/CasperHMRReloadable.swift`
  - `Sources/Casper/HMR/CasperHMRSourceClassifier.swift`
  - `Sources/Casper/HMR/CasperHMRSwiftcInvocation.swift`
  - `Sources/Casper/HMR/CasperHMRDaemon.swift`
  - `Sources/Casper/HMR/CasperHMRDebugWindow.swift`
  - `Sources/Casper/HMR/CasperHMRInterposer.swift` (Phase 0c step 12: fishhook-based runtime GOT/__la_symbol_ptr rebinding for `-interposable` Swift symbols)
  - `Sources/Casper/HMR/CasperHMRFieldOffsetPatcher.swift` (Phase 0c step 12 follow-up: copies HOST's runtime-realized Swift field-offset `Wvd` values into the dlopen'd dylib's `__DATA`; without this, NEW.apply uses compile-time placeholder offsets that omit ObjC superclass base size and corrupts NSScrollView ivars)
  - `Tools/Casper/swiftc-wrapper/` (SwiftPM executable: writes commands.jsonl, execs real swiftc)
  - `Configs/Casper-Debug.xcconfig` (wired as `baseConfigurationReference` on the cmux Debug build; sets `SWIFT_EXEC` to the wrapper and disables the integrated driver scoped to this target)
- Files (upstream files modified):
  - `Sources/cmuxApp.swift` (`#if DEBUG` call to `casperHMRBootstrap()` in `init()`; Debug menu: one `CasperHMRDebugMenuSection()` entry + one Debug-Windows button for the Recent Swaps panel)
  - `Sources/Casper/Config/CasperHMRSwiftUI.swift` (renamed from `CasperHotReload.swift` in PR 3; SwiftUI glue: `@CasperInject` propertyWrapper and `.casperHMRReload()` modifier, both subscribing to `.casperHMRReloaded` only)
  - `scripts/reload.sh` (exports `CASPER_HMR_TAG=$TAG_SLUG` and injects it into the Info.plist `LSEnvironment`)
  - `Resources/Localizable.xcstrings` (4 new keys: `casper.hmr.menu.enabled`, `casper.hmr.menu.open_recent_swaps`, `casper.hmr.window.recent_swaps.title`, `casper.hmr.window.recent_swaps.empty`)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (PBXFileReference + PBXBuildFile + Sources entries for the HMR Swift files and the xcconfig; `baseConfigurationReference` on the cmux Debug build config; direct `fishhookD` SPM dependency on `johnno1962/fishhook`)
- Summary:
  - In-process Swift hot-reload for Casper-only Debug builds. A `casper-swiftc-wrapper` SwiftPM executable intercepts swiftc invocations during xcodebuild (via `SWIFT_EXEC`) and writes one JSONL record per call to `~/.casper/hmr/<tag>/commands.jsonl`. At runtime, the daemon watches `Sources/Casper/**/*.swift` via FSEvents, recompiles the changed file with the captured argv, links it as a dylib with `-Xlinker -interposable` semantics, ad-hoc codesigns, and dlopens. **Pure-Swift dylibs do not emit `__DATA_CONST,__interpose` sections**, so the spec's static dyld-interpose path does not fire for this pipeline; `CasperHMRInterposer` walks every loaded image and rewrites GOT/`__la_symbol_ptr` slots via fishhook's `rebind_symbols_image` to redirect existing call sites (intra-host calls also route through stub tables because the host is built `-Xlinker -interposable`). Immediately before the rebind, `CasperHMRFieldOffsetPatcher` walks the NEW dylib's `LC_SYMTAB` for every `*Wvd` symbol, looks up the matching symbol in HOST images via the same Mach-O walk (file-private Wvds are not `dlsym`-able), and copies HOST's runtime-realized value into NEW's `__DATA` slot — without this, the Swift runtime's class-metadata realization (which only fires once per class) leaves NEW's Wvds at compile-time placeholders that omit the ObjC superclass base size, and any stored-property access from a swapped method crashes. SwiftUI views get re-rendered via `.casperHMRReload()` / `@CasperInject`; AppKit views via `CasperHMRReloadable` protocol + `.casperHMRReloaded` NotificationCenter post.
  - **PR 3 (this revision) deleted the InjectionLite branch entirely.** Removed: the `CASPER_HMR_NEW` gate from `cmuxApp.swift` and `reload.sh` (HMR is now unconditional in DEBUG), the `casperPrimeInjectionLogsPath` / `casperCaptureStdoutForHotReload` calls, the bootstrap-time `INJECTION_BUNDLE_NOTIFICATION` diagnostic observer, the `InjectionLite` / `DLKit` / `Popen` / `SwiftRegex5` SPM pins, and the `InjectionLite` framework link from the cmux target. Added `fishhookD` as a direct cmux SPM dependency (it used to come in transitively via InjectionLite). Renamed `CasperHotReload.swift` → `CasperHMRSwiftUI.swift`, `.casperHotReload()` modifier → `.casperHMRReload()`, and `casperHotReloadBootstrap()` → `casperHMRBootstrap()`. Any upstream changes to InjectionLite-touching call sites will conflict — resolve in favor of the casperHMR path.
  - Hardened against accidental production exposure: every HMR file is `#if DEBUG`; the daemon refuses to start under the production bundle id, under `CASPER_HMR_TAG=agent`, or when the wrapper binary isn't owned by the current user. State directory is per-tag (`~/.casper/hmr/<tag>/`) so parallel agents don't collide.
- Deletion condition:
  - Delete this entire patch (the `Sources/Casper/HMR/` directory, the `Tools/Casper/swiftc-wrapper/` package, the xcconfig, the `casperHMRBootstrap()` call in `cmuxApp.init()`, the Recent Swaps debug menu entries, the `Sources/Casper/Config/CasperHMRSwiftUI.swift` glue, the `fishhookD` SPM dep, and the four localized strings) once upstream cmux ships an in-process SwiftUI/AppKit hot-reload story.
- Verified live (Phase 0c step 12):
  - Color-change swap of `Sources/Casper/Search/CasperFindResultsView.swift` lands with `result=ok`, `interpose_entries=46`, `fo_patched=21`, `fo_unchanged=5`, `fo_missing=0`; the post-swap `outlineView.reloadData()` (which calls into the swapped `apply`, `numberOfRows`, and stored-property getters) runs without crashing. Recorded in `~/.casper/hmr/casper/events.jsonl`.

### CodeEditSourceEditor-backed text editor (flag-gated)

- Files (added):
  - `Sources/Casper/Editor/CasperEditorConfig.swift`
  - `Sources/Casper/Editor/CasperCodeEditorView.swift`
- Files (upstream files modified):
  - `Sources/Panels/FilePreviewPanel.swift` (one-line gated branch in the `.text` case of `content`)
  - `GhosttyTabs.xcodeproj/project.pbxproj` (CodeEditSourceEditor SPM package + cmux target product link)
- Summary:
  - The FilePreview panel's text branch is already an editable, saving NSTextView despite its name. This patch adds a flag-gated alternative renderer (`CasperCodeEditorView`) backed by `CodeEditSourceEditor` for syntax highlighting + line numbers + bracket emphasis. Stock cmux behavior (plain NSTextView via `FilePreviewTextEditor`) runs when `CasperEditorConfig.useCodeEditorInFilePreview` is false (the default).
  - Enable with env `CMUX_CASPER_EDITOR=1` or Info.plist key `CasperEditorEnabled = YES`. Save flow (`panel.saveTextContent()`), dirty tracking, focus coordinator integration (`attachPreviewFocus` with `.textEditor` intent), and cmd-S (via `KeyboardShortcutSettings.saveFilePreview`) all route through the existing FilePreviewPanel APIs unchanged.
- Deletion condition:
  - Delete this patch if/when upstream cmux adopts a syntax-highlighting source editor for the FilePreview text branch.

## Merge conflict notes

These upstream files are touched by fork patches and tend to drift upstream. Re-check each one when running `git merge upstream/main`:

- `Sources/ContentView.swift`
  - Heaviest conflict surface. Touched by patches 2 (sidebar reveal strips, header icon alignment animation, effective titlebar padding), the minimal-mode window-movable policy (one-line call inside the WindowAccessor refresh), and the cleanup tail. If upstream refactors sidebar layout, hidden-sidebar gap handling, or titlebar padding math, expect non-trivial manual conflict resolution.
- `Sources/AppDelegate.swift`
  - Touched by patch 2 (sidebar reveal mouse-down handlers, `cmux_sendEvent` intercept, `runSidebarRevealEdgeMouseDownLoop`) and patch 3 (new-workspace context menu shortcut display).
- `Sources/cmuxApp.swift`
  - Touched by the Casper HMR patch (one `#if DEBUG` call to `casperHMRBootstrap()` in `init()` and two Debug-menu entries). All three regions are bracketed by `// CASPER:` comments. If upstream refactors `init()` or the Debug `CommandMenu`, expect manual merge. **Post-PR-3:** any upstream patch that referenced `casperHotReloadBootstrap`, `casperPrimeInjectionLogsPath`, `casperCaptureStdoutForHotReload`, or `INJECTION_BUNDLE_NOTIFICATION` will textually conflict — resolve in favor of the casperHMR-only path (those symbols are gone).
- `Sources/WindowDecorationsController.swift`
  - Touched by the minimal-mode window-movable policy (one-line call to `CasperMinimalModeWindowMovable.apply` inside `apply(to:)`). Re-add if upstream rewrites the decorations apply path.
- `Sources/GhosttyTerminalView.swift`
  - Touched by patches 3 (rightMouseDown mouse-capture handling, menu wiring, removed legacy selectors), 4 (New Tab right-click item), and 7 (fish `XDG_DATA_DIRS` injection). High-traffic file — re-validate each region after upstream merges.
- `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift`
  - Touched by patch 2 (`hitTest()` pass-through bands for sidebar reveal). Hot path for typing latency — preserve the `isPointerEvent` guard and the interior-point early-reject.
- `Sources/Update/UpdateTitlebarAccessory.swift`, `Sources/Update/MinimalModeSidebarControls.swift`, `Sources/WindowChromeMetrics.swift`
  - Touched by patch 2 (trailing-aligned hidden controls, fullscreen breathing room, content-sized host).
- `Sources/FileExplorerSearchController.swift`, `Sources/SessionIndexStore.swift`
  - Touched by patch 6 (shared `RipgrepLocator`). Keep one locator instance; do not let either site reintroduce its own fallback list.
- `Sources/Panels/FilePreviewPanel.swift`, `Sources/FileExplorerView.swift`
  - Touched by patch 5 (.ts text-file fast-path, Finder-row icon substitution) and by the CodeEditSourceEditor patch (`.text` case in `FilePreviewPanel.content` adds a flag-gated alternative renderer).
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
