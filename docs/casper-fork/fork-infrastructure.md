# Fork infrastructure

Fork-boundary infrastructure: submodule pointers, release URLs, and the bonsplit tab-bar patches. Register index: [`docs/casper-fork.md`](../casper-fork.md).

## Casper fork infrastructure

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

## bonsplit tab-bar visibility

`.never`/`.multipleTabs` + the heyitaki/bonsplit submodule.

- Files: `.gitmodules`, `vendor/bonsplit` pin, `Sources/Workspace.swift` (top-level `tabBarVisibility: .multipleTabs` in `BonsplitConfiguration`), `Sources/GhosttyTerminalView.swift` (New Tab right-click item), `Resources/Localizable.xcstrings`
- Summary:
  - Upstream shipped its own top-level `TabBarVisibility` (.always/.multipleTabs). cmux/Casper sets `.multipleTabs` so terminals stay tabless until a pane has >1 tab. The fork's bonsplit adds `.never` (host-managed chrome) on top, plus the own-double-click guard.
- Deletion condition:
  - If upstream cmux adopts `.multipleTabs` by default, the Workspace.swift hunk dissolves; `.never` stays fork-side until upstream wants it.
