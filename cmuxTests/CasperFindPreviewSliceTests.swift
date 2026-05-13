// CASPER: Behavior tests for CasperFindPreviewSlicer.

import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CasperFindPreviewSliceTests: XCTestCase {
    func testMatchAtStartLeavesPreviewIntact() {
        let result = CasperFindPreviewSlicer.slice(preview: "game engine init", query: "game")
        XCTAssertEqual(result.text, "game engine init")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertEqual(result.matchRanges, [NSRange(location: 0, length: 4)])
    }

    func testMatchWithinBudgetLeavesPreviewIntact() {
        // Match at offset 7 (≤ explicit budget of 12)
        let result = CasperFindPreviewSlicer.slice(preview: "import game from 'engine'", query: "game", leadingBudget: 12)
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertEqual(result.text, "import game from 'engine'")
        XCTAssertEqual(result.matchRanges.first, NSRange(location: 7, length: 4))
    }

    func testMatchBeyondBudgetPrependsEllipsis() {
        let preview = "the quick brown fox jumps over the lazy dog and the game starts"
        let result = CasperFindPreviewSlicer.slice(preview: preview, query: "game", leadingBudget: 12)
        XCTAssertTrue(result.leadingEllipsis)
        XCTAssertTrue(result.text.hasPrefix("\u{2026}"))
        // 12 chars of context before match + ellipsis prefix → match starts at index 13.
        XCTAssertEqual(result.matchRanges.first, NSRange(location: 13, length: 4))
        XCTAssertTrue(result.text.contains("game starts"))
    }

    func testNoMatchReturnsPreviewUnchanged() {
        let result = CasperFindPreviewSlicer.slice(preview: "no match here", query: "missing")
        XCTAssertEqual(result.text, "no match here")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertTrue(result.matchRanges.isEmpty)
    }

    func testEmptyQueryReturnsPreviewUnchanged() {
        let result = CasperFindPreviewSlicer.slice(preview: "anything", query: "")
        XCTAssertEqual(result.text, "anything")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertTrue(result.matchRanges.isEmpty)
    }

    func testCaseInsensitiveMatch() {
        let result = CasperFindPreviewSlicer.slice(preview: "Game over", query: "game")
        XCTAssertEqual(result.matchRanges, [NSRange(location: 0, length: 4)])
    }

    func testMultipleMatchesHighlightedInOrder() {
        // After slicing (match at offset 0 keeps preview as-is) all three matches are present.
        let result = CasperFindPreviewSlicer.slice(preview: "game game game", query: "game")
        XCTAssertEqual(result.matchRanges, [
            NSRange(location: 0, length: 4),
            NSRange(location: 5, length: 4),
            NSRange(location: 10, length: 4),
        ])
    }

    func testMultipleMatchesAfterEllipsisAreRebased() {
        let preview = String(repeating: "x", count: 30) + " game and game"
        let result = CasperFindPreviewSlicer.slice(preview: preview, query: "game", leadingBudget: 12)
        XCTAssertTrue(result.leadingEllipsis)
        XCTAssertEqual(result.matchRanges.count, 2)
        XCTAssertEqual(result.matchRanges[0].location, 13)
        // Second match is 9 chars after the first ("game and ").
        XCTAssertEqual(result.matchRanges[1].location, 22)
    }

    func testQueryLongerThanPreviewReturnsUnchanged() {
        let result = CasperFindPreviewSlicer.slice(preview: "hi", query: "needle")
        XCTAssertEqual(result.text, "hi")
        XCTAssertTrue(result.matchRanges.isEmpty)
    }

    func testEmptyPreviewReturnsUnchanged() {
        let result = CasperFindPreviewSlicer.slice(preview: "", query: "game")
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.matchRanges.isEmpty)
        XCTAssertFalse(result.leadingEllipsis)
    }
}
