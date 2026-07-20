# Find-sidebar ripgrep result ranking + grouped Find UI (flag-gated)

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files (added): `Sources/Casper/Search/CasperSearchConfig.swift`, `CasperFileSearchRanking.swift`, `CasperFindResultsView.swift`, `CasperFindGroupedResults.swift`, `CasperFindPreviewSlice.swift`, `CasperFindFileIcon.swift`, `CasperFindUIConfig.swift`
- Files (upstream files modified):
  - `Sources/FileExplorerSearchController.swift` (one-line re-rank hook in `emit(status:isSearching:)` that runs `results` through `CasperFileSearchRanking.rank` before publishing the snapshot)
  - `Sources/FileExplorerView.swift` (grouped results overlay wiring, source-file icon substitution via the `FilePreviewKindResolver.isExplicitTextFile` shim)
  - `cmux.xcodeproj/project.pbxproj` (registers the new files)
- Summary:
  - Stock cmux streams ripgrep matches into the Find pane in walk order with no grouping or relevance signal, so searching `game` in a large repo can surface twenty README hits before `Game.ts`. This patch groups hits by file and tiers files by basename relevance: tier 0 = basename stem equals the query, tier 1 = basename contains the query, tier 2 = body-only match. Within each tier files sort alphabetically by relative path; within each file hits sort by line number. The re-rank runs at the snapshot boundary so the streaming pipeline is untouched.
  - Enable with env `CMUX_CASPER_SEARCH_RANKING=1` or Info.plist key `CasperSearchRankingEnabled = YES`. Brand-name fallback turns it on for Casper builds and leaves stock cmux unchanged.
- Deletion condition:
  - Delete if upstream cmux ships its own ranked Find-sidebar pipeline (e.g. Zoekt/trigram index) that supersedes this post-hoc grouping.
- Upstream status: filed as manaflow-ai/cmux#8355 (2026-07-17, branch `feat/find-grouped-results`; inlined, de-Caspered port against upstream/main plus an expansion-batching perf fix). Retire this patch at the first sync after it merges.
