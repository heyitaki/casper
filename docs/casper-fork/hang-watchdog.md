# Main-thread hang watchdog + hang-sample retention

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files (upstream files modified):
  - `Sources/App/DebugLogging.swift` (the whole `MainThreadHangWatchdog` type is Casper-only — upstream's copy of this file has no stall sampler; marked `// CASPER:`)
  - `Sources/AppDelegate.swift` (`MainThreadHangWatchdog.shared.start()` inside the existing `#if DEBUG` block in `applicationDidFinishLaunching`)
  - `cmuxTests/MainThreadHangWatchdogRetentionTests.swift` (added; registered in `project.pbxproj`)
- Summary:
  - `#if DEBUG` only. Beacons the main runloop every 100ms; when a stall exceeds 500ms, logs `watchdog.hang.start` and shells out to `/usr/bin/sample <pid> 3` for a stack dump at `/tmp/cmux-hang-sample-<pid>-<unix>.txt`, rate-limited to one per 5s. Predates the retention work (added 2026-05-18 in `0c48133a3a`); it was never registered in the fork register, which is why this section exists.
  - Retention: keep the newest `defaultRetentionKeepCount` (50) dumps globally, `CMUX_HANG_SAMPLE_KEEP` overrides, `0` means unlimited (the opt-out while actively debugging a stall). Pruned off the main thread at `start()` — which is what clears dumps left by *earlier* launches — and again after each new sample lands, so a long-lived app (the pinned Casper runs for weeks) stays bounded instead of only being swept at launch.
  - Count, not age: measured behaviour is ~14 samples per launch (a single launch never misbehaves), but ~20 tagged reloads/day × ~3 MB/sample with nothing pruning reached 1.35 GB over five days. Launch frequency drives the total, so a count bound is what actually caps it; an age bound would still let a heavy reload day blow past. A per-launch circuit breaker was considered and rejected — at any cap above ~14 it would suppress nothing.
  - Ranking parses the unix field out of the filename rather than sorting paths as strings: PIDs are variable-width, so `cmux-hang-sample-9-…` sorts above `cmux-hang-sample-100-…` lexicographically regardless of age. Covered by `testRanksByEmbeddedTimestampNotLexicographically`, whose PIDs are chosen so string order and timestamp order actively disagree (verified by mutating the sort).
  - Prune is global across PIDs, so concurrent tagged builds share one 50-dump budget. That is deliberate — the bound that matters is total disk, and per-PID retention would scale with launch count, which is the thing that broke.
- Deletion condition:
  - Delete if upstream adds its own main-thread stall sampler, or adopts this one.
