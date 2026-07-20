# Bundled universal ripgrep for Find pane

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files added: `scripts/ensure-ripgrep.sh`, `scripts/ripgrep-checksums.txt`
- Files (upstream files modified):
  - `Sources/FileExplorerSearchController.swift` (bundled `Resources/bin/rg` is the highest-priority candidate inside upstream's `RipgrepExecutableResolver` search order, after an explicitly configured custom path; plus fork pagination: `FileSearchOptions`, `loadMore()`, `FileSearchSnapshot.hasMore`, `FileSearchOutputPipeline(rootPath:hardMaxResults:initialEmissionTarget:)`)
  - `Sources/SessionIndexStore.swift` (rg resolution funnels through the same resolver)
  - `scripts/setup.sh`, `scripts/reload.sh`, `cmux.xcodeproj/project.pbxproj` ("Ensure ripgrep" PBXShellScriptBuildPhase + Copy CLI entry), `.github/workflows/release.yml`, `nightly.yml`, `.gitignore`
- Summary:
  - Bundles ripgrep universal binary at `Resources/bin/rg`; locator uses `Bundle.main.resourceURL` (not `Bundle.url(forResource:)` — copy-files-phase artifacts are invisible to it). 2026-06 merge folded the bundle-first lookup into upstream's `RipgrepExecutableResolver` (which brought Nix paths and a configured-custom-path setting).
- Deletion condition:
  - Delete when upstream bundles rg or replaces the search backend.
