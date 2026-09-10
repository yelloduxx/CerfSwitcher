import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport

final class TextReplacementAnchorTests: XCTestCase {
    private let focus = FocusedElementIdentity(processID: 42, bundleID: "test.host", identifier: "field-a")

    func testExpectedCaretAndPrefixMustBothMatch() throws {
        let anchor = try capture(prefix: "keep ", original: "ctujlyz")
        XCTAssertEqual(anchor.expectedRange(replacement: "сегодня "), NSRange(location: 0, length: 13))
        XCTAssertEqual(anchor.expectedSelection(replacement: "сегодня "), NSRange(location: 13, length: 0))
        XCTAssertEqual(verify(anchor, text: "keep сегодня "), .match)
        XCTAssertEqual(verify(anchor, text: "drop сегодня "), .mismatch)
    }

    func testLeftoverAndDuplicatedTextCannotPassBecauseTheSuffixMatches() throws {
        let anchor = try capture(prefix: "keep ", original: "ctujlyz")
        for text in ["keep cсегодня ", "keep сегоднясегодня ", "keep сегодня x"] {
            XCTAssertEqual(verify(anchor, text: text), .mismatch)
        }
    }

    func testUTF16CaretIncludesEmojiAndDecomposedPrefixWithoutNormalizingIt() throws {
        let prefix = "🙂 e\u{301}: "
        let anchor = try capture(prefix: prefix, original: "ctujlyz")
        let expected = prefix + "сегодня "
        XCTAssertEqual(anchor.expectedSelection(replacement: "сегодня ")?.location, expected.utf16.count)
        XCTAssertEqual(verify(anchor, text: expected), .match)
        XCTAssertEqual(verify(anchor, text: "🙂 é: сегодня "), .mismatch)
    }

    func testBoundedPrefixCanStartInsideALargerDocument() throws {
        let documentStart = 1_000
        let prefix = "last sentence: "
        let anchor = try capture(prefix: prefix, original: "ctujlyz", start: documentStart)
        let result = prefix + "сегодня "
        XCTAssertEqual(anchor.verify(replacement: "сегодня ", focus: focus,
                                    selection: NSRange(location: documentStart + result.utf16.count, length: 0),
                                    capturedRange: NSRange(location: documentStart, length: result.utf16.count),
                                    capturedText: result), .match)
        XCTAssertEqual(anchor.expectedRange(replacement: "сегодня ")?.location, documentStart)
    }

    func testSelectionAndDifferentFieldCannotBeConfirmed() throws {
        let anchor = try capture(prefix: "keep ", original: "ctujlyz")
        let range = try XCTUnwrap(anchor.expectedRange(replacement: "сегодня "))
        let caret = try XCTUnwrap(anchor.expectedSelection(replacement: "сегодня "))
        let other = FocusedElementIdentity(processID: 42, bundleID: "test.host", identifier: "field-b")
        XCTAssertEqual(anchor.verify(replacement: "сегодня ", focus: other, selection: caret,
                                    capturedRange: range, capturedText: "keep сегодня "), .mismatch)
        XCTAssertEqual(anchor.verify(replacement: "сегодня ", focus: focus,
                                    selection: NSRange(location: caret.location, length: 1),
                                    capturedRange: range, capturedText: "keep сегодня "), .mismatch)
    }

    func testInvalidOrPartialCaptureCannotCreateAnAnchor() {
        let caret = NSRange(location: 12, length: 0)
        let range = NSRange(location: 0, length: 12)
        XCTAssertEqual(TextReplacementAnchor.capture(expectedSuffix: "ctujlyz", focus: focus,
                                                     selection: caret, capturedRange: range,
                                                     capturedText: "keep wrong!!"), .mismatch)
        XCTAssertEqual(TextReplacementAnchor.capture(expectedSuffix: "ctujlyz", focus: focus,
                                                     selection: caret, capturedRange: range,
                                                     capturedText: "ctujlyz"), .unavailable)
        XCTAssertEqual(TextReplacementAnchor.capture(expectedSuffix: "ctujlyz",
            focus: .init(processID: 42, bundleID: "test.host", identifier: nil), selection: caret,
            capturedRange: range, capturedText: "keep ctujlyz"), .unavailable)
        let large = String(repeating: "x", count: 65) + "ctujlyz"
        XCTAssertEqual(TextReplacementAnchor.capture(expectedSuffix: "ctujlyz", focus: focus,
            selection: NSRange(location: large.utf16.count, length: 0),
            capturedRange: NSRange(location: 0, length: large.utf16.count), capturedText: large), .unavailable)
    }

    func testReadbackMustCoverTheExactAnchoredRange() throws {
        let anchor = try capture(prefix: "keep ", original: "ctujlyz")
        XCTAssertEqual(anchor.verify(replacement: "сегодня ", focus: focus,
            selection: NSRange(location: 13, length: 0), capturedRange: NSRange(location: 5, length: 8),
            capturedText: "сегодня "), .unavailable)
    }

    func testExpectedRangeArithmeticDoesNotOverflow() throws {
        let anchor = try capture(prefix: "", original: "a", start: Int.max - 2)
        XCTAssertNil(anchor.expectedRange(replacement: "abc "))
        XCTAssertNil(anchor.expectedSelection(replacement: "abc "))
    }

    private func capture(prefix: String, original: String, start: Int = 0) throws -> TextReplacementAnchor {
        let text = prefix + original
        let result = TextReplacementAnchor.capture(expectedSuffix: original, focus: focus,
            selection: NSRange(location: start + text.utf16.count, length: 0),
            capturedRange: NSRange(location: start, length: text.utf16.count), capturedText: text)
        guard case let .matched(anchor) = result else {
            XCTFail("Expected a complete matching preflight")
            throw Failure.capture
        }
        return anchor
    }

    private func verify(_ anchor: TextReplacementAnchor, text: String) -> TextContextValidation {
        anchor.verify(replacement: "сегодня ", focus: focus,
                      selection: NSRange(location: text.utf16.count, length: 0),
                      capturedRange: NSRange(location: 0, length: text.utf16.count), capturedText: text)
    }

    private enum Failure: Error { case capture }
}
