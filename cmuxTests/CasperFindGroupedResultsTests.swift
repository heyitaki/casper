// CASPER: Behavior tests for CasperFindGrouper.

import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CasperFindGroupedResultsTests: XCTestCase {
    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(CasperFindGrouper.group([]).isEmpty)
    }

    func testSingleHitProducesSingleGroup() {
        let groups = CasperFindGrouper.group([hit("src/Game.ts", line: 12)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].relativePath, "src/Game.ts")
        XCTAssertEqual(groups[0].filename, "Game.ts")
        XCTAssertEqual(groups[0].directoryDisplay, "src")
        XCTAssertEqual(groups[0].hits.count, 1)
    }

    func testFileAtRootHasEmptyDirectory() {
        let groups = CasperFindGrouper.group([hit("README.md", line: 1)])
        XCTAssertEqual(groups[0].directoryDisplay, "")
    }

    func testMultipleHitsClusterAndPreserveOrder() {
        let results = [
            hit("a/Game.ts", line: 1),
            hit("a/README.md", line: 3),
            hit("a/Game.ts", line: 5),
            hit("a/README.md", line: 9),
        ]
        let groups = CasperFindGrouper.group(results)
        XCTAssertEqual(groups.map(\.relativePath), ["a/Game.ts", "a/README.md"])
        XCTAssertEqual(groups[0].hits.map(\.lineNumber), [1, 5])
        XCTAssertEqual(groups[1].hits.map(\.lineNumber), [3, 9])
    }

    func testFileOrderingFollowsFirstAppearance() {
        // Simulates output of CasperFileSearchRanking where Game.ts (tier 0)
        // precedes README.md (tier 2).
        let results = [
            hit("src/Game.ts", line: 1),
            hit("docs/README.md", line: 7),
            hit("src/Game.ts", line: 9),
        ]
        let groups = CasperFindGrouper.group(results)
        XCTAssertEqual(groups.map(\.relativePath), ["src/Game.ts", "docs/README.md"])
    }

    func testAbsolutePathTakenFromFirstHit() {
        let results = [
            FileSearchResult(
                path: "/abs/root/src/Game.ts",
                relativePath: "src/Game.ts",
                lineNumber: 1,
                columnNumber: 1,
                preview: "preview"
            ),
            hit("src/Game.ts", line: 2),
        ]
        let groups = CasperFindGrouper.group(results)
        XCTAssertEqual(groups[0].path, "/abs/root/src/Game.ts")
    }

    private func hit(_ relativePath: String, line: Int) -> FileSearchResult {
        FileSearchResult(
            path: "/abs/" + relativePath,
            relativePath: relativePath,
            lineNumber: line,
            columnNumber: 1,
            preview: "preview"
        )
    }
}
