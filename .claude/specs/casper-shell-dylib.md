# Casper Shell + Dylib HMR

## Problem

`Casper HMR` (the daemon shipped in `.claude/specs/casper-hmr.md`) hot-swaps **individual
files inside `Sources/Casper/`** by rebuilding them as a dylib and rebinding their Swift
symbols via fishhook. In practice this misses ~everything a real edit session does:

- Edits to non-Casper files (`Sources/Find/*`, `Sources/FileExplorerView.swift`,
  `Sources/Panels/*`, anything outside `Sources/Casper/`) are silently dropped by the
  daemon's path filter.
- A brand-new file inside `Sources/Casper/` compiles fine, but no existing
  `__got` / `__la_symbol_ptr` slot points at its symbols, so fishhook has nothing
  to rebind. Result is logged as `no_interpose_for_file` and the change is invisible
  until the next full app launch.
- A type-shape change (new stored property, new conformance, new `import`) is
  correctly classified `out_of_envelope_predicted` by the source classifier and
  skipped — fishhook can't safely rebind allocation-affecting code.

Net effect: the daemon catches "edit the body of an existing function in an
existing Casper file", which is a tiny fraction of the iteration loop.

## Approach

Stop trying to make symbol-level rebinding cover the whole app. Instead, split the
app into a **thin shell binary** that owns the process, every window, and the
non-UI long-lived state, and a **fat content dylib** that owns the entire SwiftUI
view tree. On every save, rebuild only the dylib, unmount it from the shell,
`dlclose`, `dlopen` the new copy, and remount it with a state snapshot.

This is not "Swift HMR" — there is no symbol rebinding, no fishhook, no source
classifier in this path. It's a **per-frame remount** of the SwiftUI hierarchy,
sized so the frame is "everything below the NSWindow". The dylib is rebuilt as
a single SPM dynamic-library target by `swift build`, not by hand-stitched
`swiftc -emit-library` per file. That means stored-property / conformance /
new-file edits all "just work" — there is no envelope to stay inside, because
the whole content layer is rebuilt from scratch.

The existing `Casper HMR` daemon is kept (it's faster for the cases it covers
and adds zero coupling to the shell-dylib split). The dylib-remount path is the
fallback for anything the symbol-rebind path classifies as out-of-envelope or
out-of-scope.

## Constraints

- **macOS NSWindow is process-bound.** A window cannot be transferred to a new
  process. Whatever we do, it has to happen inside one `cmux` process. That
  forces dylib-level, not process-level, isolation.
- **`cmuxd` already owns the PTY masters.** Terminal sessions survive `cmux`
  relaunch today via cmuxd's socket. The shell binary inherits that contract:
  if the dylib remount preserves the cmuxd socket FD and the terminal surface
  IDs, terminal contents survive the remount with zero special handling.
- **Sparkle binds to the running bundle.** Sparkle, the menu bar extra, the
  AppleScript dispatcher, and the global event monitors all live in the shell
  and never reload.
- **`dlclose` on Swift dylibs leaks.** Every remount grows RSS by roughly the
  dylib's `__TEXT + __DATA` size. Acceptable in Debug; we'll cap remounts by
  restarting the shell at ~50 remounts (~500 MB).
- **`@StateObject` / `@Observable` identity is lost** across remount. The state
  snapshot has to capture and restore every piece of view-local state we care
  about. Truly local UI ephemera (hover, expanded rows, in-flight gesture) is
  acceptable to drop.

## Target layout

Three Xcode targets replace today's single `cmux` app target:

### `cmux-shell` (executable, signed, sandbox-free; rebuilds rarely)

Owns the process. Files that move here:

- App entry & menu bar: `cmuxApp.swift`, `cmuxApp+EqualizeSplitsMenu.swift`,
  `AppDelegate*.swift`, `App/CmuxMainWindow.swift`,
  `App/MenuBarExtraController.swift`, `App/SettingsWindowPresenter.swift`,
  `App/MainWindowVisibilityController.swift`, `AppIconDockTilePlugin.swift`,
  `AppleScriptSupport.swift`.
- Long-lived data layer: `CmuxEvent*.swift`, `CmuxConfig*.swift`,
  `CmuxSettingsJSONPathSupport.swift`, `CmuxSocketEventMapper.swift`,
  `Cloud/*`, `Auth/*`, `Update/UpdateController.swift`,
  `Update/UpdateDelegate.swift`, `Update/UpdateDriver.swift`,
  `Update/UpdateLogStore.swift`, `Update/UpdateTiming.swift`,
  `Update/UpdateTestSupport.swift`, `Update/UpdateTestURLProtocol.swift`,
  `Update/UpdateViewModel.swift`.
- Session / agent state: `SessionPersistence.swift`, `SessionIndexStore*.swift`,
  `HermesAgentIndex.swift`, `RovoDevIndex.swift`, `VaultAgent*.swift`,
  `SessionRestoredTerminalCommandStore.swift`, `RestorableAgentSession.swift`.
- Terminal/ghostty controller (model side, not view):
  `TerminalController*.swift`, `TerminalNotificationQueue.swift`,
  `TerminalNotificationStore.swift`, `TerminalStartupEnvironment.swift`,
  `TerminalSSHSessionDetector.swift`, `GhosttyApp+SurfaceConfigurationReload.swift`,
  `GhosttyConfig.swift`, `App/GhosttySurfaceConfigurationRefresh.swift`.
- Workspace/tab model (data only — view side moves to the dylib):
  `TabManager.swift`, `TabManager+*.swift`, `Workspace.swift`,
  `Workspace+*.swift` *(see Split file rule below)*,
  `WorkspaceActionDispatcher.swift`, `WorkspaceRuntimeSettings.swift`,
  `BackgroundWorkspacePrimeCoordinator.swift`.
- Casper HMR daemon (must stay in shell — can't unload itself): all of
  `Sources/Casper/HMR/*`.
- System integration: `KeyboardShortcutSettings*.swift` (file store, not UI),
  `App/CmuxCLIPathInstaller.swift`, `RemoteLoopback*.swift`,
  `RemoteRelayZshBootstrap.swift`, `SocketControlSettings.swift`,
  `PortScanner.swift`, `PostHogAnalytics.swift`, `SentryHelper.swift`,
  `CmuxActionTrust.swift`, `CmuxTopProcess*.swift`, `CmuxTopSnapshot*.swift`,
  `UITestRecorder.swift`, `CloudVMActionLauncher.swift`,
  `MainWindowFocusController.swift`, `App/DebugLogging.swift`,
  `App/SessionSnapshotDebugBenchmark.swift`,
  `App/CmuxHelpCommands.swift`, `App/CmuxHelpResource.swift`,
  `App/ScreenIdentity.swift`, `App/ShortcutBareStartRouting.swift`,
  `App/ShortcutRoutingSupport.swift`, `App/CommandPaletteShortcutRouting.swift`,
  `App/TerminalDirectoryOpenSupport.swift`,
  `App/TerminalFindEscapeRouting.swift`,
  `KeyboardShortcutSettingsLookup.swift`, `KeyboardShortcutSettingsFileStore.swift`,
  `KeyboardShortcutSettingsFileStore+Template.swift`.

### `cmux-content` (`@rpath/cmux-content.dylib`; rebuilt on every save)

Owns the SwiftUI view tree. Files that move here:

- Root content: `ContentView.swift`, `ContentView+*.swift`,
  `WorkspaceContentView.swift`, plus the SwiftUI portion of `Workspace.swift`
  (split: see "Split file rule").
- Panels: all of `Sources/Panels/*`, `Sources/Feed/*`.
- File explorer: `FileExplorerView.swift`, `FileExplorerState.swift`,
  `FileExplorerStore.swift`, `FileExplorerSearchController.swift`,
  `FileExplorerTerminalPathInsertion.swift`, `FileOpenSocketSupport.swift`,
  `FileDropOverlayView*.swift`, `FileDropHintBadgeView.swift`,
  `DetachedFolderDragIcon.swift`.
- Find / search: all of `Sources/Find/*`, plus the Casper find files —
  `Casper/Search/CasperFind*`, `Casper/Search/CasperFileSearchRanking.swift`,
  `Casper/Search/CasperSearchConfig.swift`.
- Sidebar: all of `Sources/Sidebar/*` *(view only)*, `Casper/Sidebar/*`,
  `SidebarPortDisplayText.swift`, `SidebarScrim.swift`,
  `SidebarSelectionState.swift`, `BonsplitTabBar*.swift`,
  `DockPanelView.swift`, `DockEmptyView.swift`,
  `RightSidebarPanelView.swift`, `RightSidebarChromeStyle.swift`,
  `RightSidebarChromeGeometryReporting.swift`,
  `RightSidebarMode+Availability.swift`, `RightSidebarRemoteCommand.swift`.
- Casper UI: all of `Sources/Casper/Editor/*`, `Sources/Casper/Window/*`,
  `Sources/Casper/Config/CasperHMRSwiftUI.swift`,
  `Sources/Casper/Config/CasperBuildEnvironment.swift`.
- Settings UI: `Sources/Settings/*`, `BetaFeaturesSettingsView.swift`,
  `SettingsCardNote.swift`, `SettingsNavigation.swift`,
  `SettingsSearchAliases.swift`, `AppearanceSettings.swift`,
  `KeyboardShortcutSettingsControls.swift`, `KeyboardShortcutRecorder.swift`,
  `NotificationsPage.swift`.
- Task manager UI: `TaskManagerView.swift`, `TaskManagerWindowController.swift`.
- Command palette: `Sources/CommandPalette/*`.
- Update UI surface: `Update/UpdateBadge.swift`, `Update/UpdatePill.swift`,
  `Update/UpdatePopoverView.swift`, `Update/UpdateTitlebarAccessory.swift`,
  `Update/MinimalModeSidebarControls.swift`.
- Terminal view side: `GhosttyTerminalView.swift`,
  `GhosttyTerminalViewSupport.swift`, `GhosttyTerminalAppearance.swift`,
  `GhosttyNSView+IMEComposition.swift`, `GhosttyTextInputSupport.swift`,
  `TerminalImageTransfer.swift`, `TerminalPaneDropTargetView.swift`,
  `TerminalWindowPortal.swift`, `TerminalWindowPortalDebug.swift`,
  `TmuxWorkspacePaneOverlayView.swift`,
  `Panels/TerminalPanel.swift`, `Panels/TerminalPanelView.swift`.
- Browser view side: `BrowserPaneDropTargetView.swift`,
  `BrowserWindowPortal.swift`, plus `Panels/BrowserPanel*.swift`,
  `Panels/CmuxWebView.swift`, `Panels/BrowserOmnibarPerformanceSupport.swift`,
  `Panels/BrowserPopupWindowController.swift`,
  `Panels/BrowserWebAuthnSupport.swift`, `Panels/BrowserAutomation.swift`.
- Window chrome / decoration: `WindowAccessor.swift`,
  `WindowChromeMetrics.swift`, `WindowDecorationsController.swift`,
  `WindowDragHandleView.swift`, `WindowToolbarController.swift`,
  `Windowing/*`.
- Misc UI helpers: `ShortcutHintPill.swift`,
  `WorkspaceTabColorResolution.swift`, `WorkspaceAppearanceResolution.swift`,
  `RovoDevTranscriptPreview.swift`, `SessionAgentPresentation.swift`,
  `SessionIndexView.swift`, `SessionIndexRegisteredAgents.swift`,
  `WorkspaceFinderDirectoryResolver.swift`, `WorkspacePortalPaneDrop.swift`,
  `WorkspacePromptSubmit.swift`, `WorkspaceCloseTabsBatching.swift`,
  `DragOverlayRoutingPolicy.swift`, `PaneDropRoutingSupport.swift`,
  `WorkspaceSurfaceIdentifierClipboardText.swift`,
  `WorkspaceRemoteConfiguration.swift`,
  `WorkspaceRemoteSSHBatchCommandBuilder.swift`,
  `ContentViewIdentifierCopyCommands.swift`,
  `CmuxSurfaceTabBarBuiltInAction.swift`, `CmuxSSHURLRequest.swift`,
  `RightSidebar*.swift` *(views only)*,
  `Sidebar/Sidebar*View*.swift` *(views only — drop planner / hover trackers
  stay on the dylib side because they're closure-bound from rows)*.

### `cmux-interface` (static library; rebuilds rarely; both sides import)

Pure-data types and protocols both sides need. Files that move here:

- `CmuxWorkspaceDefinition.swift`, `WorkspaceSurfaceConfig.swift`
- `SessionIndexModels.swift`, `SessionTranscriptTypes.swift`
- `MainWindowFocusTypes.swift`, `RestorableAgentTypes.swift`
- `TaskManagerTypes.swift`, `TaskManagerSnapshot.swift`
- `Backport.swift`, `JSONCParser.swift`
- `KeyboardShortcutContext.swift`, `KeyboardLayout.swift`
- (anything else the shell-vs-dylib split surfaces as a shared concrete type)

### Split file rule

A handful of files mix model and view — `Workspace.swift`,
`Workspace+PanelLifecycle.swift`, `Workspace+EqualizeSplitsSupport.swift`,
`Workspace+DetachedSurfaceTransfer.swift`,
`ContentView+MoveTabToNewWorkspace.swift`,
`ContentView+RightSidebarCommandPalette.swift`,
`ContentView+ViewCommandPalette.swift`. Each must be split into a
`*+Model.swift` (shell) and `*+View.swift` (dylib). The split is mechanical:
anything that is `Observable` / `ObservableObject` / `@Published` /
plain-struct state lives shell-side; anything that returns `some View` or
binds AppKit views lives dylib-side. **Do not** keep the file whole and pick
one side — the dylib loses its main reason to exist if its observable state
also lives in it (state snapshot becomes the whole graph).

## C-ABI surface

The shell can only see the dylib through C entrypoints. Everything else
crosses as a Swift type, which means it must come from `cmux-interface`.

```c
// cmux-content.dylib exports (extern "C"):

// Called once on dlopen. Returns 0 on success, non-zero is fatal.
int  cmux_dylib_init(const char *interface_version);

// Called once before dlclose. Returns a malloc'd JSON blob the shell will
// hand back on the next mount. Caller owns the buffer.
void cmux_dylib_finalize(uint8_t **out_state, size_t *out_state_len);

// Mount the SwiftUI hierarchy into the given NSWindow. `state` is either
// the previous finalize() output or NULL on first mount. `services` is an
// opaque pointer to a shell-owned context that exposes long-lived state
// via accessor C functions (see "Service handle" below). Returns 0 on
// success.
int  cmux_mount_app(void *nsWindow, void *services,
                    const uint8_t *state, size_t state_len);

// Unmount. After this returns the shell may dlclose() the dylib.
void cmux_unmount_app(void *nsWindow);
```

`interface_version` is `cmux-interface`'s commit SHA at build time. If the
shell's recorded SHA doesn't match the dylib's, the mount aborts and the
shell logs a clear "interface drift — rebuild shell" error. This is the only
case where a dylib remount can't recover without a shell rebuild.

### Service handle

`services` is `cmux-content`'s only path back to the shell. It's a Swift
struct allocated by the shell, retained by the dylib for the mount's
lifetime, and exposed through `cmux-interface` as a protocol the dylib's
`@EnvironmentObject` consumes. The accessors are stable enough to not
churn on every refactor:

- terminal controller: spawn / focus / send key / close
- workspace store: read snapshots, dispatch actions
- session index, agent index, vault registry: read-only views
- cmuxd socket: opaque request/response
- update controller: query status, trigger check
- preferences / appearance: read + observe
- focus controller: route command-palette / find / shortcut events

The accessor protocol lives in `cmux-interface`. The shell provides the
concrete implementation; the dylib never names it.

## State snapshot

`cmux_dylib_finalize` and `cmux_mount_app` are linked by a JSON blob the
shell stores on the heap between unmount and remount. Schema (versioned):

```json
{
  "version": 1,
  "activeWorkspaceId": "uuid",
  "workspaces": [
    {
      "id": "uuid",
      "selectedTabId": "uuid",
      "splitLayout": { ... bonsplit tree ... },
      "sidebarWidthLeft": 240,
      "sidebarWidthRight": 360,
      "rightSidebarMode": "filePreview",
      "findQuery": "...",
      "findActiveResultId": "..."
    }
  ],
  "fileExplorer": {
    "expandedDirs": ["/abs/path", ...],
    "scrollOffset": 132.0,
    "searchQuery": "..."
  },
  "commandPalette": { "lastQuery": "..." },
  "taskManager": { "filter": "...", "selection": ["id"] },
  "settings": { "lastSection": "appearance" }
}
```

Truly transient state (hover row, in-flight drag, expanded debug row,
focused text field cursor position) is intentionally omitted. Anything not
in the snapshot is reset on remount — that's the contract.

The shell holds the snapshot only between unmount and remount. After remount
the dylib re-publishes its `@Observable` instances and the shell's
session/workspace stores remain the source of truth for everything not in
the snapshot.

## Reload mechanism

1. **Build trigger.** Same FSEvents watcher the Casper HMR daemon already
   has, but with the path filter widened from `Sources/Casper/` to all of
   `Sources/` minus `Sources/App/`, `Sources/Auth/`, etc. that map to the
   shell target. Files in shell targets log a warning ("touched shell file
   X; restart cmux") and are not auto-reloaded.
2. **Compile.** `swift build --target cmux-content` (or the xcodebuild
   equivalent against the dylib scheme). Output: `cmux-content.dylib`
   under the shell's `Frameworks/` path. Ad-hoc codesigned.
3. **Unmount.** Shell calls `cmux_unmount_app(window)`, then
   `cmux_dylib_finalize(&buf, &len)`, stashes `buf`/`len`, then `dlclose`s
   the handle. The NSWindow stays alive; its `contentView` is replaced
   by a small "Reloading…" host that the shell owns.
4. **Mount.** Shell `dlopen`s the new dylib, looks up `cmux_dylib_init` and
   `cmux_mount_app`, calls them in that order. On success the placeholder
   host is removed.
5. **Failure.** If `cmx_dylib_init` returns non-zero or the dylib fails to
   load (bad interface version, missing symbol, codesign mismatch), the
   shell keeps the placeholder up and surfaces an error in the Debug menu.
   The previous dylib is gone — a successful next build recovers.

The reload is triggered three ways:

- **Auto** — FSEvents detects a `.swift` save in the dylib's path set and
  the Casper-HMR symbol-rebind path classifies the change as
  `out_of_envelope` or `no_interpose_for_file`. Auto-reload then takes
  ~3-6s on a warm `swift build`.
- **Menu** — `Debug > Reload Content` (always available).
- **Shortcut** — `⌘⌃R` (configurable).

## Migration plan (7 PRs, ~3-4 weeks)

Each PR is independently shippable: every step leaves the app building and
running, with the dylib path off by default until **PR D**.

- **PR A — Carve `cmux-interface`.** Move pure-data files out of
  `cmux` into a new static library target. No behavior change. Largest
  churn: import statements. ~1 day.
- **PR B — Define ABI.** Add `cmux-content` target as an *empty* dynamic
  library. Define `cmux_dylib_init` / `cmux_mount_app` / `cmux_unmount_app`
  / `cmux_dylib_finalize` exports. Define the `CmuxShellServices`
  protocol in `cmux-interface`. Shell links the dylib statically for now;
  no dlopen yet. ~2 days.
- **PR C — Move ContentView only.** Migrate `ContentView.swift` and its
  immediate dependencies to `cmux-content`. Snapshot is empty. Verify the
  app still launches when the dylib is statically linked. ~2 days.
- **PR D — Reload menu item.** Switch the shell to `dlopen`-load
  `cmux-content` at startup. Add `Debug > Reload Content`. State snapshot
  is empty (lose all view state on reload). At this point the system is
  functional for the ContentView-sized seam — the Reload button works.
  Gate behind `CASPER_SHELL_DYLIB=1`. ~3 days.
- **PR E1-E3 — Panel clusters.** Three PRs, one per cluster:
  E1 = file explorer + find, E2 = panels (terminal/browser views,
  preview, markdown, PDF), E3 = sidebar + workspace content. Each PR
  expands `cmux-content` and grows the snapshot schema. ~1 week total.
- **PR F — Settings + task manager + remaining UI.** Move Settings/*,
  TaskManager view, command palette, update-UI surface, Casper UI files.
  Snapshot adds settings-section / task-manager-selection fields.
  ~3 days.
- **PR G — Auto-reload on FSEvents.** Wire the Casper HMR daemon's
  classifier to fall back to dylib remount on `out_of_envelope` /
  `no_interpose_for_file`. Lift the `Sources/Casper/` path filter for
  the remount path only — the symbol-rebind path keeps its filter.
  Default-on in DEBUG. ~2 days.

After PR G the iteration loop is: save any file in `Sources/` (except
shell-only directories) → ≤6s later the SwiftUI tree is the new version,
terminal panes are intact, and the workspace is on the same selected tab.

## Open questions (resolve before PR D)

1. **`GhosttyTerminalView` lives on the seam.** It's a SwiftUI view that
   wraps a long-lived AppKit surface bound to a cmuxd-owned PTY. Putting
   the view in `cmux-content` is fine — but does the AppKit surface
   survive view-tree teardown? Likely yes (it's retained by
   `TerminalController` on the shell side), but needs a probe in PR C.
2. **Symbol stripping in Release.** `cmux-content` must be `#if DEBUG`-only
   — the Release shell links the content layer statically. The dual-build
   discipline needs to be a build-time guard, not a runtime check.
3. **dlclose RSS growth.** Confirm the ~50-remount cap is realistic by
   measuring `vmmap` after 5 / 10 / 20 forced remounts. If it's worse than
   ~10 MB/remount, add a "shell self-restart" path that preserves the
   cmuxd socket FD across exec.
4. **Sparkle update mid-session.** Sparkle replaces the bundle on disk
   when an update lands. Confirm the running shell + dylib continue to
   work until restart (they should — both files are mmap'd, not re-read).
