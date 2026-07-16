// CASPER: Behavior tests for CasperArchiveStore — archive membership, the
// typed-input arming rule for submit-unarchive, and prune semantics.

import AppKit
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CasperArchiveStoreTests: XCTestCase {
    private var store: CasperArchiveStore!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CasperArchiveStoreTests.\(UUID().uuidString)"
        store = CasperArchiveStore(defaults: UserDefaults(suiteName: defaultsSuiteName)!)
    }

    override func tearDown() {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    func testArchiveAndToggle() {
        let panel = UUID()
        XCTAssertFalse(store.hasArchivedSessions)
        store.archive(panel)
        XCTAssertTrue(store.isArchived(panel))
        store.toggle(panel)
        XCTAssertFalse(store.isArchived(panel))
        store.toggle(panel)
        XCTAssertTrue(store.isArchived(panel))
    }

    /// A bare Return (dismissing a pager, confirming a TUI prompt) must NOT
    /// unarchive: only a Return that follows typed input counts as a submit.
    /// Regression test for the Jul 2026 "archive silently drained during a
    /// long run, looked like a restart bug" incident.
    func testBareReturnSubmitDoesNotUnarchiveWithoutTypedInput() {
        let panel = UUID()
        store.archive(panel)
        store.noteUserSubmit(panelId: panel)
        XCTAssertTrue(store.isArchived(panel), "Submit without prior typed input must keep the session archived")
    }

    func testSubmitAfterTypedInputUnarchives() {
        let panel = UUID()
        store.archive(panel)
        store.noteTypedInput(panelId: panel)
        store.noteUserSubmit(panelId: panel)
        XCTAssertFalse(store.isArchived(panel))
    }

    /// A Feed reply is composed text by construction, so it bypasses the
    /// terminal-keystroke arming requirement.
    func testSubmitWithoutTypingRequirementUnarchives() {
        let panel = UUID()
        store.archive(panel)
        store.noteUserSubmit(panelId: panel, requireTypedInput: false)
        XCTAssertFalse(store.isArchived(panel))
    }

    /// Re-archiving must clear the typed-input arming from the previous
    /// archived stint — otherwise the next bare Return unarchives again.
    func testRearchiveClearsTypedArming() {
        let panel = UUID()
        store.archive(panel)
        store.noteTypedInput(panelId: panel)
        store.noteUserSubmit(panelId: panel)
        XCTAssertFalse(store.isArchived(panel))

        store.archive(panel)
        store.noteUserSubmit(panelId: panel)
        XCTAssertTrue(store.isArchived(panel), "Arming must not survive an unarchive/archive cycle")
    }

    func testTypedInputOnUnarchivedPanelDoesNotArm() {
        let panel = UUID()
        store.noteTypedInput(panelId: panel)
        store.archive(panel)
        store.noteUserSubmit(panelId: panel)
        XCTAssertTrue(store.isArchived(panel), "Typing before archiving must not pre-arm the panel")
    }

    func testArchivePanelsInsertsAllAndSubmitRespectsArming() {
        let a = UUID(), b = UUID()
        store.archivePanels([a, b])
        XCTAssertTrue(store.isArchived(a))
        XCTAssertTrue(store.isArchived(b))
        store.noteTypedInput(panelId: a)
        store.noteUserSubmit(panelId: a)
        store.noteUserSubmit(panelId: b)
        XCTAssertFalse(store.isArchived(a))
        XCTAssertTrue(store.isArchived(b))
    }

    /// "Archive Workspace" passes the workspace's full panel set, including
    /// panels that are already archived — the batch must not disarm those.
    func testArchivePanelsKeepsExistingArming() {
        let a = UUID(), b = UUID()
        store.archive(a)
        store.noteTypedInput(panelId: a)
        store.archivePanels([a, b])
        store.noteUserSubmit(panelId: a)
        XCTAssertFalse(store.isArchived(a), "Batch archive must not disarm an already-armed archived panel")
        XCTAssertTrue(store.isArchived(b))
    }

    func testPruneMissingDropsOnlyMissing() {
        let live = UUID(), gone = UUID()
        store.archivePanels([live, gone])
        store.pruneMissing(livePanelIds: [live])
        XCTAssertTrue(store.isArchived(live))
        XCTAssertFalse(store.isArchived(gone))
    }

    // MARK: - Submit / composing keystroke detection

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testSubmitReturnDetection() {
        XCTAssertTrue(CasperArchiveSubmitDetector.isSubmitReturn(keyEvent(keyCode: 36, characters: "\r")))
        XCTAssertTrue(CasperArchiveSubmitDetector.isSubmitReturn(keyEvent(keyCode: 76, characters: "\u{3}")))
        XCTAssertFalse(CasperArchiveSubmitDetector.isSubmitReturn(keyEvent(keyCode: 36, characters: "\r", modifierFlags: .shift)))
        XCTAssertFalse(CasperArchiveSubmitDetector.isSubmitReturn(keyEvent(keyCode: 36, characters: "\r", modifierFlags: .option)))
        XCTAssertFalse(CasperArchiveSubmitDetector.isSubmitReturn(keyEvent(keyCode: 0, characters: "a")))
    }

    func testComposingKeystrokeDetection() {
        XCTAssertTrue(CasperArchiveSubmitDetector.isComposingKeystroke(keyEvent(keyCode: 0, characters: "a")))
        XCTAssertTrue(CasperArchiveSubmitDetector.isComposingKeystroke(keyEvent(keyCode: 51, characters: "\u{7F}")))
        // Shift+Return composes a newline in agent TUIs.
        XCTAssertTrue(CasperArchiveSubmitDetector.isComposingKeystroke(keyEvent(keyCode: 36, characters: "\r", modifierFlags: .shift)))
        // Navigation/control gestures do not compose.
        XCTAssertFalse(CasperArchiveSubmitDetector.isComposingKeystroke(
            keyEvent(keyCode: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifierFlags: .function)
        ))
        XCTAssertFalse(CasperArchiveSubmitDetector.isComposingKeystroke(keyEvent(keyCode: 53, characters: "\u{1B}")))
        XCTAssertFalse(CasperArchiveSubmitDetector.isComposingKeystroke(keyEvent(keyCode: 8, characters: "c", modifierFlags: .command)))
        XCTAssertFalse(CasperArchiveSubmitDetector.isComposingKeystroke(keyEvent(keyCode: 8, characters: "\u{3}", modifierFlags: .control)))
    }
}
