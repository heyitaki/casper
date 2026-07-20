# Small CASPER hunks

One-hunk patches too small for their own doc. Grep `// CASPER:` for the authoritative in-tree list. Register index: [`docs/casper-fork.md`](../casper-fork.md).

- `Sources/AppDelegate.swift` — `isModalOrSheetPresented` (gates alert key-equivalent scan per keystroke).
- `Sources/TerminalController.swift` — `shouldReplacePorts` guard on the ports `@Published` write.
- `Sources/VaultAgentProcessScanner.swift` — pid-keyed argv parse cache (`VaultAgentArgvCache`).
- `Sources/Workspace.swift` — `appendLog` compatibility seam (left from the sub-store retirement; fold into call sites when convenient).
- `CLI/cmux.swift` — Codex `prompt-submit` pushes the prompt as a soft sidebar title (`surface.set_title`).
- `Resources/bin/cmux-claude-wrapper` — no startup socket gate (hooks connect independently); shim self-detection also matches the renamed wrapper path.
- `Sources/RestorableAgentSession.swift` — `freshLaunchShellCommand` + orphan-transcript fallback for resume.
