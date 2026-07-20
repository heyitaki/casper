# Restore-time agent workspace warmup (parallel)

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files (added): `Sources/Casper/CasperStartupAgentWarmup.swift`, `Sources/Casper/Concurrency/CasperBoundedAsyncWorkPool.swift`, `cmuxTests/CasperStartupAgentWarmupTests.swift`
- Files (upstream files modified):
  - `Sources/AppDelegate.swift` (two one-line hooks in `applySessionWindowSnapshot` and `createMainWindow`, gated on `CasperBuildEnvironment.isBranded`, calling `CasperStartupAgentWarmup.applyStartupWarmup`)
  - `Sources/BackgroundWorkspacePrimeCoordinator.swift` (sequential `for` over pending IDs replaced with a rolling `withTaskGroup` capped at `min(pending, Policy.maxConcurrentPrimes)`, where the cap is `activeProcessorCount` with thermal-state downshift; upstream's `.noSurfaceWork` early-exits folded in)
  - `cmux.xcodeproj/project.pbxproj` (registers the new files)
- Summary:
  - On Casper launch, eagerly background-prime agent workspaces so their `claude --resume` / `codex resume` / etc. sessions resume on app open instead of waiting for a manual click. Selection ranks by `max(statusEntries.timestamp, logEntries.timestamp)` with tab-order fallback, caps at 5 per restore, skips the already-selected workspace, and requires `panels[].terminal.agent` to be set in the snapshot (i.e., an agent was attached at last save).
  - Gated on `AgentSessionAutoResumeSettings.isEnabled()` — if the user disabled auto-resume, `restoredAgentResumeInput` is nil and a warmed shell would be empty.
  - Reuses the upstream `BackgroundWorkspacePrime` pipeline end to end (`requestBackgroundWorkspaceLoad` → `pendingBackgroundWorkspaceLoadIds` → coordinator hidden mount → surface start → `initialInput` flush). The only Casper-specific bit is the selection policy.
  - To prevent 5 sequential 2 s timeouts compounding to ~10 s, the coordinator now drives `primeBackgroundWorkspaceIfNeeded` in parallel via a bounded `withTaskGroup`. Cap is `min(pending, activeProcessorCount)` with thermal downshift (serious → cores/2, critical → 1). Per-workspace state stays serialized on `@MainActor`; parallelism is only across the suspension points in `waitForBackgroundWorkspacePrimeCompletion`. This parallelization is general and could be upstreamed independently of the Casper warmup selector.
  - The former cheap/heavy session-autosave fingerprint split was **dropped** in the 2026-06 merge: upstream's `ProcessDetectedResumeIndexes` has no process-scan-free cheap path. If autosave cost shows up in profiles again, rebuild the optimization against that API.
- Deletion condition:
  - Delete `CasperStartupAgentWarmup` + the two AppDelegate hooks if upstream cmux adds a restore-time background prime over the existing `restoredAgentAutoResumePendingPanelIds` set.
  - Delete the `BackgroundWorkspacePrimeCoordinator` patch if upstream rewrites the coordinator to drive primes concurrently itself.
