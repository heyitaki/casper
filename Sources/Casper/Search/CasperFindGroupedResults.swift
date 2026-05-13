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

        var hitsByPath: [String: [FileSearchResult]] = [:]
        var pathOrder: [String] = []

        for result in results {
            if hitsByPath[result.relativePath] == nil {
                pathOrder.append(result.relativePath)
            }
            hitsByPath[result.relativePath, default: []].append(result)
        }

        return pathOrder.map { relativePath in
            let hits = hitsByPath[relativePath] ?? []
            let absolutePath = hits.first?.path ?? relativePath
            let nsRelative = relativePath as NSString
            let filename = nsRelative.lastPathComponent
            let parent = nsRelative.deletingLastPathComponent
            return CasperFindFileGroup(
                path: absolutePath,
                relativePath: relativePath,
                filename: filename,
                directoryDisplay: parent,
                hits: hits
            )
        }
    }
}
