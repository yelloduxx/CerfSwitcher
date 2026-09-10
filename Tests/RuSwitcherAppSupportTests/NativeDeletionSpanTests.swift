import AppKit
import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

@MainActor
final class NativeDeletionSpanTests: XCTestCase {
    func testAmbiguousUnicodeCannotDeleteThePrecedingSentence() {
        for suffix in ["ghbdtn\u{1F642}", "ghbdtn\u{1F469}\u{200D}\u{1F4BB}", "cafe\u{0301}"] {
            let editor = WindowlessEditor(suffix: suffix)
            let before = editor.view.string
            let coordinator = NativeReplacementCoordinator(reader: editor, poster: editor)
            let result = coordinator.submit(editor.request(deliveredKeys: suffix.count)) { _ in
                XCTFail("An ambiguous deletion must not be posted or learned")
            }
            XCTAssertEqual(result, .blocked(.ambiguousDeletion))
            XCTAssertEqual(editor.posts, 0)
            XCTAssertEqual(editor.view.string, before)
        }
    }

    func testExtraPhysicalKeysCannotExpandDeletionBeyondVerifiedText() {
        let editor = WindowlessEditor(suffix: "ghbdtn")
        let coordinator = NativeReplacementCoordinator(reader: editor, poster: editor)
        var confirmed: ReplacementOutcome?
        XCTAssertEqual(coordinator.submit(editor.request(deliveredKeys: 8)) { confirmed = $0 }, .postedUnverified)
        XCTAssertEqual(editor.view.string, editor.prefix + "replacement ")
        XCTAssertEqual(editor.posts, 1)
        XCTAssertEqual(confirmed, .verified)
    }
}

// Actual AppKit editing commands, but no window, AX call or global event posting.
@MainActor
private final class WindowlessEditor: FocusedTextContextReading, KeyboardEventPosting {
    let prefix = "Keep the earlier sentence. "
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    let focus = FocusedElementIdentity(processID: 1, bundleID: "test.editor", identifier: "field")
    let suffix: String
    var posts = 0

    init(suffix: String) {
        self.suffix = suffix
        view.isRichText = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.string = prefix + suffix
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
    }

    func request(deliveredKeys: Int) -> ReplacementRequest {
        let transaction = ConversionTransaction(original: suffix, replacement: "replacement", boundary: .space(count: 1),
                                                focus: focus, sourceLayoutID: "en", targetLayoutID: "ru",
                                                sequence: 1, automatic: true)
        return .init(transaction: transaction, deliveredKeyCount: deliveredKeys, currentFocus: focus, currentRevision: 0)
    }

    func validate(expectedSuffix: String, focus: FocusedElementIdentity, deadlineMilliseconds: Int) -> TextContextPreflight {
        TextReplacementAnchor.capture(expectedSuffix: expectedSuffix, focus: focus, selection: view.selectedRange(),
                                      capturedRange: NSRange(location: 0, length: view.string.utf16.count), capturedText: view.string)
    }

    func verify(expectedSuffix: String, anchor: TextReplacementAnchor, deadlineMilliseconds: Int,
                completion: @escaping @MainActor (TextContextValidation) -> Void) {
        completion(anchor.verify(replacement: expectedSuffix, focus: focus, selection: view.selectedRange(),
                                 capturedRange: NSRange(location: 0, length: view.string.utf16.count), capturedText: view.string))
    }

    func post(_ plan: EventReplacementPlan, to processID: Int32, delivery: KeyboardEventDelivery) -> Bool {
        posts += 1
        for _ in 0..<plan.backspaceCount { view.deleteBackward(nil) }
        view.insertText(plan.insertedText, replacementRange: view.selectedRange())
        return true
    }
}
