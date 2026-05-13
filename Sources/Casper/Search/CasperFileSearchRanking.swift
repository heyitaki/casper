// CASPER: Re-rank Find-sidebar ripgrep results so basename matches outrank body-only matches and hits cluster per file; rg streams in walk order with no relevance signal.

import Foundation

enum CasperFileSearchRanking {
    /// Stable re-rank of arrival-order ripgrep results into:
    /// 1) files whose basename stem equals the query (`game` → `Game.ts`),
    /// 2) files whose basename contains the query (`game` → `gamepiece.tsx`),
    /// 3) everything else.
    /// Within each tier, files sort alphabetically by relative path; within
    /// each file, hits sort by line number.
    static func rank(_ results: [FileSearchResult], query: String) -> [FileSearchResult] {
        guard CasperSearchConfig.rankFindResults else { return results }
        return apply(to: results, query: query)
    }

    static func apply(to results: [FileSearchResult], query: String) -> [FileSearchResult] {
        guard results.count > 1 else { return results }
        let lowerQuery = query.lowercased()
        guard !lowerQuery.isEmpty else { return results }

        var hitsByPath: [String: [FileSearchResult]] = [:]
        var tierByPath: [String: Int] = [:]
        var lowerByPath: [String: String] = [:]
        var insertionOrder: [String] = []

        for result in results {
            let path = result.relativePath
            if tierByPath[path] == nil {
                let basename = (path as NSString).lastPathComponent
                let stem = (basename as NSString).deletingPathExtension
                let basenameLower = basename.lowercased()
                let stemLower = stem.lowercased()
                let tier: Int
                if stemLower == lowerQuery {
                    tier = 0
                } else if basenameLower.contains(lowerQuery) {
                    tier = 1
                } else {
                    tier = 2
                }
                tierByPath[path] = tier
                lowerByPath[path] = path.lowercased()
                insertionOrder.append(path)
            }
            hitsByPath[path, default: []].append(result)
        }

        let sortedKeys = insertionOrder.sorted { lhs, rhs in
            let lhsTier = tierByPath[lhs] ?? 2
            let rhsTier = tierByPath[rhs] ?? 2
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            // Already-lowercased keys: plain `<` is byte-order alphabetical and
            // ~10× faster than `localizedCaseInsensitiveCompare`. Stable across
            // identical lowercase forms because `sorted` is stable in Swift.
            return (lowerByPath[lhs] ?? lhs) < (lowerByPath[rhs] ?? rhs)
        }
        return sortedKeys.flatMap { key in
            (hitsByPath[key] ?? []).sorted { $0.lineNumber < $1.lineNumber }
        }
    }
}
