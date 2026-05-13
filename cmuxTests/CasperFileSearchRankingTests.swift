// CASPER: Behavior tests for the Casper Find-sidebar re-ranker (CasperFileSearchRanking).

import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CasperFileSearchRankingTests: XCTestCase {
    func testStemEqualBeatsContains() {
        let results = [
            hit("docs/gameplay.md", line: 12),
            hit("src/Game.ts", line: 7),
        ]
        let ranked = CasperFileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(ranked.map(\.relativePath), ["src/Game.ts", "docs/gameplay.md"])
    }

    func testContainsBeatsBodyOnly() {
        let results = [
            hit("README.md", line: 3),
            hit("src/gamepiece.tsx", line: 42),
        ]
        let ranked = CasperFileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(ranked.map(\.relativePath), ["src/gamepiece.tsx", "README.md"])
    }

    func testHitsClusterPerFileAndSortByLine() {
        let results = [
            hit("a/Game.ts", line: 5),
            hit("a/README.md", line: 2),
            hit("a/Game.ts", line: 1),
            hit("a/README.md", line: 9),
            hit("a/Game.ts", line: 3),
        ]
        let ranked = CasperFileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(
            ranked.map { "\($0.relativePath):\($0.lineNumber)" },
            ["a/Game.ts:1", "a/Game.ts:3", "a/Game.ts:5", "a/README.md:2", "a/README.md:9"]
        )
    }

    func testAlphaSortWithinTierIsCaseInsensitive() {
        // `Dab.md` vs `cab.md` distinguishes case-insensitive ordering (c < d)
        // from raw ASCII byte order (D=68 < c=99). The other paths add a wider
        // alphabetic spread so a regression to ASCII order fails loudly.
        let results = [
            hit("src/zoo.ts", line: 1),
            hit("src/aardvark.md", line: 1),
            hit("src/Bear.swift", line: 1),
            hit("src/Dab.md", line: 1),
            hit("src/cab.md", line: 1),
        ]
        let ranked = CasperFileSearchRanking.apply(to: results, query: "missing")
        XCTAssertEqual(
            ranked.map(\.relativePath),
            ["src/aardvark.md", "src/Bear.swift", "src/cab.md", "src/Dab.md", "src/zoo.ts"]
        )
    }

    func testEmptyQueryReturnsInputUnchanged() {
        let results = [hit("a.ts", line: 1), hit("b.ts", line: 1)]
        XCTAssertEqual(CasperFileSearchRanking.apply(to: results, query: ""), results)
    }

    func testSingleResultShortCircuits() {
        let results = [hit("a.ts", line: 1)]
        XCTAssertEqual(CasperFileSearchRanking.apply(to: results, query: "anything"), results)
    }

    func testCaseInsensitiveBasenameMatch() {
        let results = [
            hit("UPPER/HIT.TS", line: 1),
            hit("body/note.md", line: 1),
        ]
        let ranked = CasperFileSearchRanking.apply(to: results, query: "hit")
        XCTAssertEqual(ranked.first?.relativePath, "UPPER/HIT.TS")
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
