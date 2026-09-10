import Foundation
import XCTest
import RuSwitcherTestSupport

final class VirtualTextEditorTests: XCTestCase {
    private let emoji = "\u{1F469}\u{200D}\u{1F4BB}"
    private let accented = "e\u{301}"

    func testInitialCaretUsesUTF16LengthAndStartsAtRevisionZero() {
        let empty = VirtualTextEditor()
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.revision, 0)

        let editor = VirtualTextEditor(text: "a" + emoji + accented)
        XCTAssertEqual(editor.text, "a" + emoji + accented)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(editor.revision, 0)
    }

    func testInsertionAtCaretPreservesBothSides() throws {
        var editor = VirtualTextEditor(text: "a" + emoji + "z")
        try editor.setSelection(NSRange(location: 1, length: 0))
        editor.insert(accented)
        XCTAssertEqual(editor.text, "a" + accented + emoji + "z")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }

    func testInsertionReplacesExactlyTheSelectedGraphemes() throws {
        var editor = VirtualTextEditor(text: "left " + emoji + " right")
        try editor.setSelection(NSRange(location: 5, length: 5))
        editor.insert(accented)
        XCTAssertEqual(editor.text, "left " + accented + " right")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }

    func testEmptyInsertionDeletesASelectionButOtherwiseDoesNothing() throws {
        var editor = VirtualTextEditor(text: "abc")
        editor.insert("")
        XCTAssertEqual(editor.revision, 0)
        try editor.setSelection(NSRange(location: 1, length: 1))
        editor.insert("")
        XCTAssertEqual(editor.text, "ac")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.revision, 2)
        editor.insert("")
        XCTAssertEqual(editor.revision, 2)
    }

    func testBackspaceDeletesWholeDecomposedAndJoinedGraphemes() {
        var editor = VirtualTextEditor(text: "a" + emoji + accented)
        editor.backspace()
        XCTAssertEqual(editor.text, "a" + emoji)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(editor.revision, 1)
        editor.backspace()
        XCTAssertEqual(editor.text, "a")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }

    func testBackspaceAtInteriorCaretPreservesFollowingText() throws {
        var editor = VirtualTextEditor(text: "a" + emoji + "z")
        try editor.setSelection(NSRange(location: 6, length: 0))
        editor.backspace()
        XCTAssertEqual(editor.text, "az")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }

    func testBackspaceDeletesSelectionWithoutAnExtraCharacter() throws {
        var editor = VirtualTextEditor(text: "a" + emoji + accented + "z")
        try editor.setSelection(NSRange(location: 1, length: 7))
        editor.backspace()
        XCTAssertEqual(editor.text, "az")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }

    func testBackspaceAtZeroIsANoOpForEmptyAndNonemptyText() throws {
        for text in ["", emoji + accented] {
            var editor = VirtualTextEditor(text: text)
            try editor.setSelection(NSRange(location: 0, length: 0))
            let revision = editor.revision
            editor.backspace()
            XCTAssertEqual(editor.text, text)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
            XCTAssertEqual(editor.revision, revision)
        }
    }

    func testMovementCountsGraphemesAndClampsExtremeDistances() {
        var editor = VirtualTextEditor(text: "a" + emoji + accented + "z")
        for offset in [8, 6, 1, 0] {
            editor.moveCaret(byCharacters: -1)
            XCTAssertEqual(editor.selectedRange, NSRange(location: offset, length: 0))
        }
        XCTAssertEqual(editor.revision, 4)
        editor.moveCaret(byCharacters: Int.min)
        editor.moveCaret(byCharacters: 0)
        XCTAssertEqual(editor.revision, 4)
        editor.moveCaret(byCharacters: 2)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 6, length: 0))
        editor.moveCaret(byCharacters: Int.max)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 9, length: 0))
        XCTAssertEqual(editor.revision, 6)
        editor.moveCaret(byCharacters: Int.max)
        XCTAssertEqual(editor.revision, 6)
        editor.moveCaret(byCharacters: Int.min)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.revision, 7)
        XCTAssertEqual(editor.text, "a" + emoji + accented + "z")
    }

    func testExtendedMovementRetainsAnchorWhenCrossingIt() throws {
        var editor = VirtualTextEditor(text: "a" + emoji + accented + "z")
        try editor.setSelection(NSRange(location: 6, length: 0))
        editor.moveCaret(byCharacters: -2, extendingSelection: true)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 6))
        XCTAssertFalse(editor.hasSuffixBeforeCaret("a"))
        editor.moveCaret(byCharacters: 1, extendingSelection: true)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 5))
        XCTAssertTrue(editor.hasSuffixBeforeCaret("a"))
        editor.moveCaret(byCharacters: 2, extendingSelection: true)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 6, length: 2))
        XCTAssertTrue(editor.hasSuffixBeforeCaret(accented))
        XCTAssertEqual(editor.revision, 4)
        editor.insert("X")
        XCTAssertEqual(editor.text, "a" + emoji + "Xz")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(editor.revision, 5)
    }

    func testMovementCollapsesSelectionBeforeTakingRemainingSteps() throws {
        for (distance, offset) in [(-1, 2), (1, 4), (-2, 1), (2, 5), (Int.min, 0), (Int.max, 6)] {
            var editor = VirtualTextEditor(text: "abcdef")
            try editor.setSelection(NSRange(location: 2, length: 2))
            editor.moveCaret(byCharacters: distance)
            XCTAssertEqual(editor.selectedRange, NSRange(location: offset, length: 0))
            XCTAssertEqual(editor.text, "abcdef")
            XCTAssertEqual(editor.revision, 2)
        }
    }

    func testInvalidAndSplitGraphemeRangesLeaveStateUntouched() throws {
        var editor = VirtualTextEditor(text: "a" + emoji + accented + "z")
        try editor.setSelection(NSRange(location: 1, length: 5))
        let invalid = [
            NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
            NSRange(location: NSNotFound, length: 0), NSRange(location: 1, length: Int.max),
            NSRange(location: Int.max, length: Int.max), NSRange(location: 10, length: 0),
            NSRange(location: 9, length: 1), NSRange(location: 0, length: 10),
            NSRange(location: 2, length: 0), NSRange(location: 1, length: 1),
            NSRange(location: 3, length: 0), NSRange(location: 1, length: 3),
            NSRange(location: 7, length: 0), NSRange(location: 6, length: 1),
        ]
        for range in invalid {
            XCTAssertThrowsError(try editor.setSelection(range)) { error in
                XCTAssertEqual(error as? VirtualTextEditor.SelectionError, .invalidRange(range))
            }
            XCTAssertEqual(editor.text, "a" + emoji + accented + "z")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 5))
            XCTAssertEqual(editor.revision, 1)
        }
        editor.moveCaret(byCharacters: -1, extendingSelection: true)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }

    func testRevisionChangesOncePerActualEditOrCaretMove() throws {
        var editor = VirtualTextEditor(text: "abc")
        try editor.setSelection(NSRange(location: 3, length: 0))
        editor.moveCaret(byCharacters: 1)
        editor.moveCaret(byCharacters: -1)
        XCTAssertEqual(editor.revision, 1)
        try editor.setSelection(NSRange(location: 1, length: 1))
        try editor.setSelection(NSRange(location: 1, length: 1))
        editor.moveCaret(byCharacters: 0)
        XCTAssertEqual(editor.revision, 2)
        editor.insert("b")
        XCTAssertEqual(editor.text, "abc")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(editor.revision, 3, "Collapsing the selection is a real change even with identical text")
        editor.insert("X")
        XCTAssertEqual(editor.text, "abXc")
        XCTAssertEqual(editor.revision, 4)
    }

    func testSuffixUsesActiveCaretAndWholeGraphemesWithoutMutating() throws {
        var editor = VirtualTextEditor(text: "a" + emoji + accented + "z")
        try editor.setSelection(NSRange(location: 1, length: 7))
        XCTAssertTrue(editor.hasSuffixBeforeCaret(emoji + accented))
        XCTAssertTrue(editor.hasSuffixBeforeCaret("\u{E9}"))
        XCTAssertFalse(editor.hasSuffixBeforeCaret("\u{301}"))
        XCTAssertFalse(editor.hasSuffixBeforeCaret("z"))
        XCTAssertFalse(editor.hasSuffixBeforeCaret("longer than the text before the caret"))
        XCTAssertTrue(editor.hasSuffixBeforeCaret(""))
        XCTAssertEqual(editor.revision, 1)
        editor.moveCaret(byCharacters: -1, extendingSelection: true)
        XCTAssertTrue(editor.hasSuffixBeforeCaret(emoji))
        XCTAssertFalse(editor.hasSuffixBeforeCaret("\u{1F4BB}"))
        try editor.setSelection(NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasSuffixBeforeCaret(""))
        XCTAssertFalse(editor.hasSuffixBeforeCaret("a"))
    }

    func testInsertionResegmentationNeverLeavesCaretInsideAGrapheme() throws {
        var editor = VirtualTextEditor(text: "\u{301}z")
        try editor.setSelection(NSRange(location: 0, length: 0))
        editor.insert("e")
        XCTAssertEqual(Array(editor.text.utf16), [0x65, 0x301, 0x7A])
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(editor.revision, 2)
        editor.backspace()
        XCTAssertEqual(editor.text, "z")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))

        editor = VirtualTextEditor(text: "ez")
        try editor.setSelection(NSRange(location: 1, length: 0))
        editor.insert("\u{301}")
        XCTAssertEqual(Array(editor.text.utf16), [0x65, 0x301, 0x7A])
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0))
    }

    func testDeletionResegmentationKeepsMergedEmojiAndSurroundingText() throws {
        var editor = VirtualTextEditor(text: "\u{1F1FA}x\u{1F1F8}!")
        try editor.setSelection(NSRange(location: 3, length: 0))
        editor.backspace()
        XCTAssertEqual(editor.text, "\u{1F1FA}\u{1F1F8}!")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.revision, 2)
        editor.backspace()
        XCTAssertEqual(editor.text, "!")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.revision, 3)
    }

    func testCanonicallyEquivalentReplacementPreservesRequestedUTF16Storage() throws {
        var editor = VirtualTextEditor(text: "x\u{E9}z")
        try editor.setSelection(NSRange(location: 1, length: 1))
        editor.insert(accented)
        XCTAssertEqual(Array(editor.text.utf16), [0x78, 0x65, 0x301, 0x7A])
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(editor.revision, 2)
    }
}
