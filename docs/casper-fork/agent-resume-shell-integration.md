# Agent-resume shell integration

Two patches in the same bug family: restored/resumed agent panels silently losing cmux shell integration (and therefore hooks), one per shell. The fish patch fixes panels that start with a non-empty initial command; the zsh patch fixes the resume launcher's `ZDOTDIR` ordering. Register index: [`docs/casper-fork.md`](../casper-fork.md).

## Fish integration via vendor_conf.d

Loaded env-based, survives an initial command.

- Files (added):
  - `Resources/shell-integration/fish/vendor_conf.d/cmux-shell-integration.fish`
  - `cmuxTests/FishShellIntegrationTests.swift` (`testFishIntegrationLoadsFromVendorConfWithoutInitCommand`, `testVendorConfLoaderDoesNotDoubleSourceUserConfigWhenShellIsNotFish`; the file itself is upstream)
- Files (upstream files modified):
  - `Sources/GhosttyTerminalView.swift` — the `XDG_DATA_DIRS` injection this loader depends on (the `// Make <integrationDir>/fish/vendor_conf.d/...` hunk) is Casper-only and previously unowned by any patch section. It is claimed here. `cf1a8c7b6d` deleted the loader but left the injection, so from that merge until this patch the app exported an `XDG_DATA_DIRS` entry pointing at a directory with no `vendor_conf.d` — a dangling injection, and the loudest available signal that the retirement was wrong.
- Scope (read this before assuming it fixes a resume bug):
  - **fish-only.** cmux picks the integration branch by `$SHELL`, so a user whose login shell is zsh or bash never reaches the fish branch and is entirely unaffected by this patch. The zsh equivalent of this bug is the ZDOTDIR re-entry patch below, which is a different mechanism and the one that actually bit us.
- Summary:
  - Upstream injects fish integration through the *shell command*: `managedFishShellCommand` builds `fish -il --init-command 'source "$CMUX_FISH_INTEGRATION_FILE"'`, applied under `if baseConfig.command?.isEmpty != false`. Restored agent panels set `baseConfig.command` to the resume launcher script, so that branch never runs and those panels get **no** fish integration — no `claude` function, so `claude` resolves through `PATH` to a user-installed binary (e.g. `~/.local/bin/claude` from the native installer) and starts with no cmux hooks. The session never registers in `~/.cmuxterm/claude-hook-sessions.json` and is silently unrestorable on the next launch. zsh/bash reach the same end state by a different route (the ZDOTDIR patch below), not via this branch.
  - Fish sources `$XDG_DATA_DIRS/fish/vendor_conf.d/*.fish` on every startup, so this loader is env-based and applies to every panel regardless of the initial command. It just sources the sibling upstream `config.fish`, keeping the upstream-file footprint at zero for `config.fish` itself. Ghostty ships its own integration the same way.
  - Two guards the loader must carry, both because `vendor_conf.d` runs in a different slot than `--init-command` (before the user's config rather than after, and on every fish rather than only interactive ones):
    - `status is-interactive; or return` — `config.fish` has no interactivity guard of its own (upstream never needed one), so without this every `fish -c` from a build script writes a shim, chmods it, and mutates `PATH`.
    - seed `CMUX_FISH_USER_CONFIG_ALREADY_LOADED` — `config.fish:257` sources the user's own `conf.d` + `config.fish` when it is unset. cmux sets it only in the fish branch, so it is absent whenever `$SHELL` is zsh/bash and the user runs `fish` by hand; without the seed the user's whole fish config is sourced twice (measured).
  - Double-*loading* is harmless in panels that get both mechanisms: `_cmux_install_cli_wrapper` early-returns via `functions -q`, and `_cmux_path_prepend_unique_directory` dedupes. Verified. That is a narrower claim than load-*order* safety, which the two guards above cover.
- Deletion condition:
  - Delete if upstream loads its fish integration from `vendor_conf.d`, or via any other env-based mechanism that survives a non-empty `baseConfig.command`.

## Resume launcher ZDOTDIR re-entry

The resume launcher re-enters cmux's `ZDOTDIR` before running the resume command.

- Files (upstream files modified):
  - `Sources/SessionPersistence.swift` (`TerminalStartupReturnShellScript.commandThenReturnLines`: `zshIntegrationReentryLines` hoisted above the `case`, marked `// CASPER:`)
  - `cmuxTests/AgentSessionAutoResumeSettingsTests.swift` (`testResumeLauncherReentersCmuxZdotdirBeforeRunningResumeCommand`; the file itself is upstream)
- Summary:
  - cmux's `.zshenv` restores the user's `ZDOTDIR` as soon as it loads, so by the time the resume launcher script runs, `ZDOTDIR` is the user's again. `commandThenReturnLines` emitted the re-entry block *after* the `case` that runs the resume command, so `zsh -lic '<agent> --resume …'` loaded only the user's config: no cmux integration, therefore no `claude` shell function, therefore `claude` resolved through `PATH` to whatever binary the user has installed (e.g. `~/.local/bin/claude`, which the native Claude installer added on 2026-07-15) and started with **no cmux hooks injected**.
  - Consequence: every resumed agent ran unregistered and never reported to `~/.cmuxterm/claude-hook-sessions.json`. Confirmed in the field — all 27 resumed `claude --resume` processes carried no `--settings`, and the hook store had frozen at the previous app restart. Sessions survived restore only via the sticky `restoredAgentSnapshotsByPanelId` cache; anything not already in that cache was silently lost.
  - Hoisting is safe: the block is zsh-gated and only exports, so the trailing `exec -l` sees `ZDOTDIR` exactly as before. Verified directly: `whence -w claude` in the resume shell goes from `claude: command` to `claude: function`.
  - **This is general, not Casper-specific — upstream it.** It affects any upstream cmux user whose `$SHELL` is zsh. Note bash is not covered either way: the `case` sends `zsh|bash` to `-lic`, but the re-entry block is zsh-only, so bash resumes remain unhooked (pre-existing, untouched here).
- Deletion condition:
  - Delete if upstream reorders this itself, or stops restoring `ZDOTDIR` in `.zshenv`.
