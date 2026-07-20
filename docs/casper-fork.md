# Casper Fork Changes (heyitaki/cmux)

`heyitaki/cmux` is a fork of `manaflow-ai/cmux`. We carry these local patches indefinitely; do not assume any will be upstreamed. The point of this register is to make `git merge upstream/main` cheap by giving the merger a map of where fork-only hunks live, why they exist, and what would obviate them.

See `CLAUDE.md` → "Upstream merge strategy (Casper fork)" for the discipline. This file is the concise per-patch index; each entry links to a detail doc in [`docs/casper-fork/`](casper-fork/) with files touched, rationale, and deletion conditions.

## Current merge debt

As of 2026-06-09, `heyitaki/cmux:main` is **caught up** with `manaflow-ai/cmux:main` via the latest `git merge upstream/main` (~1,830 upstream commits merged, including the project rename to `cmux.xcodeproj`, the `@Observable SidebarDragState` sidebar rewrite, first-class workspace groups, upstream fish integration, and the CmuxControlSocket extraction). Both submodules were sub-merged and pushed to their heyitaki fork `main` branches first (ghostty `813986fdf`, bonsplit `1541b4ae`).

Patches retired by merges are listed in [retired patches](casper-fork/retired.md).

**Hot paths to preserve during future conflict resolution.** `TerminalWindowPortal.hitTest()` and `BrowserWindowPortal.hitTest()` are typing-latency-critical (see `CLAUDE.md` → "Pitfalls"). Upstream replaced the manual `isPointerEvent` guard with `WindowInputRoutingContext.allowsPortalPointerHitTesting` — semantically equivalent; keep that guard and the interior-point early-reject intact.

## Fork update checklist

1) Land the change on `main` (or via PR against `heyitaki/cmux`).
2) Add or update the patch's detail doc in `docs/casper-fork/` and its one-line entry in this index.
3) If the change modifies any upstream cmux file, add a `// CASPER: <reason>; delete if upstream adds <X>` comment on the modified hunk so the next merger can grep for it.
4) Add the touched upstream files to [merge conflict notes](casper-fork/merge-conflict-notes.md) if they're not already listed.

## Active fork patches

### Sidebar

- [Compact panel-keyed sidebar](casper-fork/compact-sidebar.md) — one row per terminal panel, activity-sorted inside repo-path groups, with a 4-state agent-activity indicator and per-session JSONL recency.
- [Session navigation & row context menu](casper-fork/sidebar-session-navigation.md) — ⌘↑/↓ and ⌘⇧↑/↓ session/workspace nav, per-session row ordering, row context menu.
- [Group selection (⌘1…9) + ⌘W group close + empty window](casper-fork/sidebar-group-selection.md) — digits select folder groups, group context menu, batched close/reopen, last-workspace close leaves an empty window.
- [Session archive](casper-fork/session-archive.md) — collapsible Archive section; a session returns to active only on a typed-then-submitted command, Feed reply, or explicit menu action.
- [Fork Conversation surfaces](casper-fork/fork-conversation.md) — upstream's Fork Conversation exposed in the session-row and panel right-click menus with a destination submenu.
- [Footer trimmed to a settings entry point](casper-fork/sidebar-footer.md) — footer reduced to a gear button with Keyboard Shortcuts + Import Browser Data.

### Windowing & input

- [Minimal-mode sidebar and reveal strips](casper-fork/minimal-mode-sidebar.md) — minimal presentation by default; 5pt edge strips reveal the sidebar; trimmed titlebar button cluster.
- [Minimal-mode window-movable policy](casper-fork/minimal-mode-sidebar.md#minimal-mode-window-movable-policy) — `isMovable = false` so AppKit titlebar-drag can't hijack bonsplit tab drags.
- [First-mouse gate scope](casper-fork/activation-and-first-mouse.md) — upstream's #3856 gate only swallows true app-activation clicks, not in-app key borrowing.
- [Activation-desync repair](casper-fork/activation-and-first-mouse.md#activation-desync-repair) — recovers from AppKit's stuck `NSApp.isActive == false` state ("sidebar dead until Space switch").

### Terminal & shell

- [Panel right-click menu unification](casper-fork/panel-context-menu.md) — one shared Split/New Tab/Close/Move menu path across all panel types; right-click works under terminal mouse capture.
- [Fish integration via vendor_conf.d](casper-fork/agent-resume-shell-integration.md) — env-based loading so panels with an initial command (restored agents) still get cmux integration.
- [Resume launcher ZDOTDIR re-entry](casper-fork/agent-resume-shell-integration.md#resume-launcher-zdotdir-re-entry) — re-enters cmux's zsh integration before the resume command so resumed agents keep their hooks; upstream candidate.

### Search & files

- [Bundled universal ripgrep](casper-fork/bundled-ripgrep.md) — `Resources/bin/rg` as the highest-priority resolver candidate; Find-pane pagination.
- [Find result ranking + grouped UI](casper-fork/find-ranking.md) — hits grouped by file, tiered by basename relevance; flag-gated; filed upstream as manaflow-ai/cmux#8355.

### Startup & persistence

- [Restore-time agent workspace warmup](casper-fork/startup-agent-warmup.md) — background-primes up to 5 agent workspaces in parallel at launch so `claude --resume` is live on first click.

### Infra & debug

- [Fork infrastructure](casper-fork/fork-infrastructure.md) — heyitaki submodule pointers, release URLs, xcframework fetch.
- [bonsplit tab-bar visibility](casper-fork/fork-infrastructure.md#bonsplit-tab-bar-visibility) — `.multipleTabs` default + fork-side `.never` case and double-click guard.
- [Debug-log gating](casper-fork/debug-log-gating.md) — stops per-keystroke hitTest walks and log writes in daily-driver DEBUG builds.
- [Main-thread hang watchdog](casper-fork/hang-watchdog.md) — DEBUG stall sampler with count-bounded `/tmp` dump retention.
- [Small CASPER hunks](casper-fork/small-casper-hunks.md) — one-hunk patches; grep `// CASPER:` for the authoritative in-tree list.

## Merge map

Per-file conflict guidance for `git merge upstream/main` lives in [merge conflict notes](casper-fork/merge-conflict-notes.md).

## Retired patches

Patches obviated by upstream merges (and one un-retirement) are recorded in [retired patches](casper-fork/retired.md).
