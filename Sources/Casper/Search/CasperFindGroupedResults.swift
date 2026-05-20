// CASPER: Folds the flat [FileSearchResult] coming out of FileSearchController into per-file groups for the VS Code-style grouped Find sidebar. Preserves the file ordering from CasperFileSearchRanking so the file/path ranking still wins; within a group hits arrive in the order they were emitted (already line-sorted by the ranker).

import Foundation

struct CasperFindFileGroup: Equatable {
    let path: String
    let relativePath: String
    let filename: String
    /// Parent directory of `relativePath`, with no trailing slash. Empty when
    /// the file sits at the workspace root.
    let directoryDisplay: String
    let hits: [FileSearchResult]
}

enum CasperFindGrouper {
    static func group(_ results: [FileSearchResult]) -> [CasperFindFileGroup] {
        if results.isEmpty { return [] }

        // Pre-size for the worst case (every hit a new file). Over-estimates
        // when most hits cluster, but a single `reserveCapacity` is cheaper
        // than the 2–3 rehashes a streaming dictionary would do.
        var hitsByPath: [String: [FileSearchResult]] = [:]
        hitsByPath.reserveCapacity(results.count)
        var pathOrder: [String] = []
        pathOrder.reserveCapacity(results.count)

        for result in results {
            let path = result.relativePath
            if hitsByPath[path] == nil {
                pathOrder.append(path)
            }
            hitsByPath[path, default: []].append(result)
        }

        var groups: [CasperFindFileGroup] = []
        groups.reserveCapacity(pathOrder.count)
        for relativePath in pathOrder {
            let hits = hitsByPath[relativePath] ?? []
            let absolutePath = hits.first?.path ?? relativePath
            let nsRelative = relativePath as NSString
            let filename = nsRelative.lastPathComponent
            let parent = nsRelative.deletingLastPathComponent
            groups.append(CasperFindFileGroup(
                path: absolutePath,
                relativePath: relativePath,
                filename: filename,
                directoryDisplay: parent,
                hits: hits
            ))
        }
        return groups
    }
}
