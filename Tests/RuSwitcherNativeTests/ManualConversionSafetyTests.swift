import XCTest
import RuSwitcherAppSupport
import RuSwitcherCore
@testable import RuSwitcher

final class ManualConversionSafetyTests: XCTestCase {
    func testSelectedReadbackRetryUsesOnlyRemainingAXBudget() {
        let deadline: UInt64 = 150_000_000
        XCTAssertEqual(TextConverter.selectedReadbackTimeoutMilliseconds(deadline: deadline, now: 0), 150)
        XCTAssertEqual(TextConverter.selectedReadbackTimeoutMilliseconds(deadline: deadline, now: 149_000_000), 1)
        XCTAssertNil(TextConverter.selectedReadbackTimeoutMilliseconds(deadline: deadline, now: 149_000_001))
        XCTAssertNil(TextConverter.selectedReadbackTimeoutMilliseconds(deadline: deadline, now: deadline))
        XCTAssertNil(TextConverter.selectedReadbackTimeoutMilliseconds(deadline: deadline, now: deadline + 10_000_000))
    }

    func testReplacementProofRejectsInsertionWithoutRemoval() throws {
        let evidence = try XCTUnwrap(ManualReplacementEvidence(document: "ghbdtn", original: "ghbdtn",
            range: NSRange(location: 0, length: 6)))
        XCTAssertEqual(evidence.verify("привет", replacement: "привет"), .match)
        XCTAssertEqual(evidence.verify("приветghbdtn", replacement: "привет"), .mismatch)
        XCTAssertEqual(evidence.verify("ghbdtnпривет", replacement: "привет"), .mismatch)
        XCTAssertEqual(evidence.verify("ghbdtn", replacement: "привет"), .unchanged)
    }

    func testReplacementProofRequiresBothNeighborsToRemainExact() throws {
        let evidence = try XCTUnwrap(ManualReplacementEvidence(document: "left ghbdtn right", original: "ghbdtn",
            range: NSRange(location: 5, length: 6)))
        XCTAssertEqual(evidence.verify("left привет right", replacement: "привет"), .match)
        for actual in ["left приветghbdtn right", "left привет wrong", "lost привет right", "привет"] {
            XCTAssertEqual(evidence.verify(actual, replacement: "привет"), .mismatch)
        }
    }

    func testReplacementProofAllowsOriginalTextOutsideReplacedSpan() throws {
        let evidence = try XCTUnwrap(ManualReplacementEvidence(document: "ghbdtn ghbdtn", original: "ghbdtn",
            range: NSRange(location: 0, length: 6)))
        XCTAssertEqual(evidence.verify("привет ghbdtn", replacement: "привет"), .match)
        XCTAssertEqual(evidence.verify("ghbdtn привет", replacement: "привет"), .mismatch)
    }

    func testReplacementProofUsesUTF16OffsetsAndHandlesLengthChanges() throws {
        let prefix = "\u{1F642} e\u{301} "
        let evidence = try XCTUnwrap(ManualReplacementEvidence(document: prefix + "abc tail", original: "abc",
            range: NSRange(location: prefix.utf16.count, length: 3)))
        XCTAssertEqual(evidence.verify(prefix + "x tail", replacement: "x"), .match)
        XCTAssertEqual(evidence.verify(prefix + "longer tail", replacement: "longer"), .match)
        XCTAssertEqual(evidence.verify(prefix + "xbc tail", replacement: "x"), .mismatch)
        XCTAssertEqual(evidence.verify("\u{1F642} é x tail", replacement: "x"), .mismatch)
    }

    func testReplacementProofRequiresReadableDocumentAndValidOriginalSpan() throws {
        XCTAssertNil(ManualReplacementEvidence(document: nil, original: "abc", range: NSRange(location: 0, length: 3)))
        for range in [NSRange(location: -1, length: 3), NSRange(location: 0, length: 0),
                      NSRange(location: 0, length: 4), NSRange(location: NSNotFound, length: Int.max)] {
            XCTAssertNil(ManualReplacementEvidence(document: "abc", original: "abc", range: range))
        }
        XCTAssertNil(ManualReplacementEvidence(document: "xyz", original: "abc", range: NSRange(location: 0, length: 3)))
        let evidence = try XCTUnwrap(ManualReplacementEvidence(document: "abc", original: "abc",
            range: NSRange(location: 0, length: 3)))
        XCTAssertEqual(evidence.verify(nil, replacement: "xyz"), .unavailable)
    }

    func testMutationRechecksFreshnessAfterBlockingValidation() {
        var current = true
        var mutations = 0
        let result = ManualMutationSafety.perform(validation: {
            current = false
            return nil
        }, refusal: { current ? nil : .editorChanged }, mutation: {
            mutations += 1
            return .match
        })
        XCTAssertEqual(result, .notAttempted(.editorChanged))
        XCTAssertEqual(mutations, 0)
    }

    func testMutationRefusesInvalidSelectionWithoutWriting() {
        var mutations = 0
        let result = ManualMutationSafety.perform(validation: { .editorChanged }, refusal: { nil }, mutation: {
            mutations += 1
            return .match
        })
        XCTAssertEqual(result, .notAttempted(.editorChanged))
        XCTAssertEqual(mutations, 0)
    }

    func testCurrentMutationRunsOnceAndDoesNotRetryMismatch() {
        var mutations = 0
        let result = ManualMutationSafety.perform(validation: { nil }, refusal: { nil }, mutation: {
            mutations += 1
            return .mismatch
        })
        XCTAssertEqual(result, .mismatch)
        XCTAssertEqual(mutations, 1)
    }

    func testKeyboardReplacementRequiresExactReadableSelection() {
        let range = NSRange(location: 7, length: 6)
        XCTAssertFalse(ManualMutationSafety.matchesSelectionText(nil, expected: "ghbdtn", range: range))
        XCTAssertFalse(ManualMutationSafety.matchesSelectionText("foreign", expected: "ghbdtn", range: range))
        XCTAssertFalse(ManualMutationSafety.matchesSelectionText("", expected: "", range: range))
        XCTAssertTrue(ManualMutationSafety.matchesSelectionText("ghbdtn", expected: "ghbdtn", range: range))
        XCTAssertFalse(ManualMutationSafety.matchesSelectionText("ghbdtn ", expected: "ghbdtn", range: range))
    }

    func testSelectionValidationRejectsUnsafeRangesWithoutDocumentEvidence() {
        for range in [NSRange(location: -1, length: 6), NSRange(location: 0, length: -1),
                      NSRange(location: 0, length: 0), NSRange(location: 0, length: 5),
                      NSRange(location: Int.max, length: 6)] {
            XCTAssertFalse(ManualMutationSafety.matchesSelectionText("ghbdtn", expected: "ghbdtn", range: range))
        }
    }

    func testDocumentProofDoesNotReadAXValueWithoutBoundedCharacterCount() {
        for count in [nil, -1, 65_537, Int.max] as [Int?] {
            var reads = 0
            XCTAssertNil(ManualReplacementEvidence.readBoundedDocument(characterCount: count) {
                reads += 1
                return "text"
            })
            XCTAssertEqual(reads, 0)
        }
    }

    func testDocumentProofRequiresReturnedUTF16LengthToMatchAXCount() {
        XCTAssertEqual(ManualReplacementEvidence.readBoundedDocument(characterCount: 2) { "\u{1F642}" }, "\u{1F642}")
        XCTAssertNil(ManualReplacementEvidence.readBoundedDocument(characterCount: 1) { "\u{1F642}" })
        XCTAssertNil(ManualReplacementEvidence.readBoundedDocument(characterCount: 6) { nil })
        let limit = String(repeating: "a", count: 65_536)
        XCTAssertEqual(ManualReplacementEvidence.readBoundedDocument(characterCount: 65_536) { limit }, limit)
        XCTAssertNil(ManualReplacementEvidence(document: limit + "x", original: "a",
            range: NSRange(location: 0, length: 1)))
    }

    func testStaleCompletionCannotReleaseNewOperation() throws {
        var operations = ManualOperationOwnership()
        let first = try XCTUnwrap(operations.begin())
        operations.cancel()
        let second = try XCTUnwrap(operations.begin())
        XCTAssertFalse(operations.finish(first))
        XCTAssertTrue(operations.owns(second))
        XCTAssertNil(operations.begin())
        XCTAssertTrue(operations.finish(second))
        XCTAssertNil(operations.activeID)
    }

    func testBusyTriggerAndDuplicateCompletionDoNotCancelOwner() throws {
        var operations = ManualOperationOwnership()
        let first = try XCTUnwrap(operations.begin())
        XCTAssertNil(operations.begin())
        XCTAssertTrue(operations.owns(first))
        XCTAssertTrue(operations.finish(first))
        let second = try XCTUnwrap(operations.begin())
        XCTAssertFalse(operations.finish(first))
        XCTAssertTrue(operations.owns(second))
    }

    func testReadbackOutcomesDoNotTreatMismatchAsUnavailable() {
        let cases: [(ReplacementVerification, SelectedTextConversionOutcome, ManualSuffixReplacementOutcome)] = [
            (.match, .converted, .verified),
            (.unavailable, .postedUnverified, .postedUnverified),
            (.unchanged, .failed, .failed),
            (.mismatch, .failed, .failed),
            (.notAttempted(.editorChanged), .blocked(.editorChanged), .blocked(.editorChanged)),
            (.notAttempted(.fieldUnavailable), .blocked(.fieldUnavailable), .blocked(.fieldUnavailable)),
        ]
        for (verification, selected, suffix) in cases {
            XCTAssertEqual(SelectedTextConversionOutcome(verification: verification), selected)
            XCTAssertEqual(ManualSuffixReplacementOutcome(verification: verification), suffix)
        }
    }

    func testKnownUnreadableSelectionCannotFallThroughToBufferedWord() {
        XCTAssertEqual(SelectedTextConversionOutcome.unreadableSelection(selectionKnown: true),
            .blocked(.fieldUnavailable))
        XCTAssertEqual(SelectedTextConversionOutcome.unreadableSelection(selectionKnown: false), .none)
    }

    @MainActor
    func testSelectedPhraseRepeatPreservesExactSpanAndBothLayouts() async throws {
        let converter = TextConverter(focusedElementResolver: NativeFocusedEditableResolver())
        let focus = FocusedElementIdentity(processID: 123, bundleID: "test.editor", identifier: "field-a")
        let prefix = "prefix "
        let suffix = " untouched suffix"
        let original = "  ghbdtn  vbh\t"
        let converted = "  привет  мир\t"
        let transaction = ConversionTransaction(original: original, replacement: converted,
            boundary: .punctuation(""), focus: focus, sourceLayoutID: "en", targetLayoutID: "ru",
            sequence: 1, automatic: false)
        converter.recordVerifiedSelection(transaction, selectionLocation: prefix.utf16.count)

        for (expected, replacement, target) in [(converted, original, "en"), (original, converted, "ru"),
                                               (converted, original, "en")] {
            let repeatPlan = try XCTUnwrap(converter.prepareReconversion())
            XCTAssertEqual(repeatPlan.current, expected)
            XCTAssertEqual(repeatPlan.replacement, replacement)
            XCTAssertEqual(repeatPlan.targetLayoutID, target)
            XCTAssertEqual(repeatPlan.focus, focus)
            XCTAssertEqual(repeatPlan.expectedCaretLocation, prefix.utf16.count + expected.utf16.count)
            let document = prefix + expected + suffix
            let range = NSRange(location: prefix.utf16.count, length: repeatPlan.current.utf16.count)
            XCTAssertEqual((document as NSString).replacingCharacters(in: range, with: repeatPlan.replacement),
                prefix + replacement + suffix)
            converter.recordPostedReconversion(repeatPlan, transaction: ConversionTransaction(
                original: expected, replacement: replacement, boundary: .punctuation(""), focus: focus,
                sourceLayoutID: "unrelated-active-layout", targetLayoutID: target,
                sequence: 2, automatic: false))
        }
    }

    @MainActor
    func testSelectedWhitespaceAndAdditionalSpacesAreNotTrimmed() async throws {
        let converter = TextConverter(focusedElementResolver: NativeFocusedEditableResolver())
        converter.recordVerifiedSelection(selectionTransaction(), selectionLocation: 7)
        let plan = try XCTUnwrap(converter.prepareReconversion(trailingSpaces: 2))
        XCTAssertEqual(plan.current, "  привет мир\t  ")
        XCTAssertEqual(plan.replacement, "  ghbdtn vbh\t  ")
        XCTAssertEqual(plan.expectedCaretLocation, 7 + "  привет мир\t  ".utf16.count)
    }

    @MainActor
    func testStaleRefusalsPreserveRememberedSelectionWithoutReadingEditor() async {
        let converter = TextConverter(focusedElementResolver: NativeFocusedEditableResolver())
        let transaction = selectionTransaction()
        converter.recordVerifiedSelection(transaction, selectionLocation: 7)
        var selectionOutcome: SelectedTextConversionOutcome?
        converter.convertSelectedText(isCurrent: { false }) { selectionOutcome = $0 }
        XCTAssertEqual(selectionOutcome, .blocked(.editorChanged))
        var suffixOutcome: ManualSuffixReplacementOutcome?
        converter.replaceFocusedSuffix(expected: transaction.replacement, replacement: transaction.original,
            focus: transaction.focus, isCurrent: { false }) { suffixOutcome = $0 }
        XCTAssertEqual(suffixOutcome, .blocked(.editorChanged))
        XCTAssertEqual(converter.lastTransaction, transaction)
        XCTAssertTrue(converter.canReconvert)
        XCTAssertEqual(converter.prepareReconversion()?.current, transaction.replacement)
        XCTAssertEqual(converter.lastLearningPair?.original, transaction.original)
    }

    @MainActor
    func testNewTransactionAndClearStateDiscardSelectionAnchor() async {
        let converter = TextConverter(focusedElementResolver: NativeFocusedEditableResolver())
        converter.recordVerifiedSelection(selectionTransaction(), selectionLocation: 7)
        converter.recordCommittedTransaction(selectionTransaction())
        XCTAssertNil(converter.prepareReconversion()?.expectedCaretLocation)
        XCTAssertNil(converter.prepareReconversion()?.focus)
        converter.clearState()
        XCTAssertFalse(converter.canReconvert)
        XCTAssertNil(converter.prepareReconversion())
    }

    private func selectionTransaction() -> ConversionTransaction {
        ConversionTransaction(original: "  ghbdtn vbh\t", replacement: "  привет мир\t",
            boundary: .punctuation(""),
            focus: FocusedElementIdentity(processID: 123, bundleID: "test.editor", identifier: "field-a"),
            sourceLayoutID: "en", targetLayoutID: "ru", sequence: 1, automatic: false)
    }
}
