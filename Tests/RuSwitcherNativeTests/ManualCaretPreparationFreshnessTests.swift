import XCTest
import RuSwitcherCore
@testable import RuSwitcher

final class ManualCaretPreparationFreshnessTests: XCTestCase {
    @MainActor
    func testNoCandidateAfterImmediateTypingIsRefused() {
        var session = InputSession()
        let expected = snapshot(session)
        for keyCode: UInt16 in [2, 15, 0, 3, 17] {
            session.append(TypedKey(keyCode: keyCode, shift: false, caps: false))
        }
        XCTAssertEqual(session.editRevision, expected.editRevision)
        assertEditorChanged(AppDelegate.validatedCaretWordPreparationOutcome(
            .noCandidate, expected: expected, current: snapshot(session)))
        XCTAssertEqual(session.currentKeys.count, 5)
    }

    @MainActor
    func testNoCandidateAfterTypingAndDeletingIsRefused() {
        var session = InputSession()
        let expected = snapshot(session)
        session.append(TypedKey(keyCode: 2, shift: false, caps: false))
        session.removeLast()
        XCTAssertTrue(session.currentKeys.isEmpty)
        assertEditorChanged(AppDelegate.validatedCaretWordPreparationOutcome(
            .noCandidate, expected: expected, current: snapshot(session)))
    }

    @MainActor
    func testNoCandidateWithChangedRevisionAloneIsRefused() {
        assertEditorChanged(AppDelegate.validatedCaretWordPreparationOutcome(
            .noCandidate, expected: snapshot(), current: snapshot(editRevision: 1)))
    }

    @MainActor
    func testNewInputRefusesEveryPreparationOutcome() {
        for outcome in outcomes {
            assertEditorChanged(AppDelegate.validatedCaretWordPreparationOutcome(
                outcome, expected: snapshot(), current: snapshot(sequence: 1)))
        }
    }

    @MainActor
    func testMissingEditorRefusesEveryPreparationOutcome() {
        for outcome in outcomes {
            assertEditorChanged(AppDelegate.validatedCaretWordPreparationOutcome(
                outcome, expected: snapshot(), current: nil))
        }
    }

    @MainActor
    func testChangedFocusRefusesEveryPreparationOutcome() {
        let changedFields = [
            FocusedElementIdentity(processID: 124, bundleID: "test.editor", identifier: "field-a"),
            FocusedElementIdentity(processID: 123, bundleID: "other.editor", identifier: "field-a"),
            FocusedElementIdentity(processID: 123, bundleID: "test.editor", identifier: "field-b"),
            FocusedElementIdentity(processID: 123, bundleID: "test.editor", identifier: nil),
        ]
        for focus in changedFields {
            for outcome in outcomes {
                assertEditorChanged(AppDelegate.validatedCaretWordPreparationOutcome(
                    outcome, expected: snapshot(), current: snapshot(focus: focus)))
            }
        }
    }

    @MainActor
    func testMatchingNoCandidatePreservesSwitchOnlyOutcome() {
        guard case .noCandidate = AppDelegate.validatedCaretWordPreparationOutcome(
            .noCandidate, expected: snapshot(), current: snapshot()) else {
            return XCTFail("Fresh empty-caret preparation must still allow switch-only completion")
        }
    }

    @MainActor
    func testMatchingBusyAndBlockedKeepTheirOutcomes() {
        guard case .busy = AppDelegate.validatedCaretWordPreparationOutcome(
            .busy, expected: snapshot(), current: snapshot()) else {
            return XCTFail("Fresh busy preparation must still allow its bounded retry")
        }
        guard case .blocked(.fieldUnavailable) = AppDelegate.validatedCaretWordPreparationOutcome(
            .blocked(.fieldUnavailable), expected: snapshot(), current: snapshot()) else {
            return XCTFail("Fresh blocked preparation must preserve its refusal reason")
        }
    }

    @MainActor
    func testMatchingInvalidatedEditorPreservesExactCaretRecovery() {
        var session = InputSession()
        session.handle(.navigation)
        let expected = snapshot(session)
        guard case let .conversion(actual) = AppDelegate.validatedCaretWordPreparationOutcome(
            .conversion(conversion), expected: expected, current: expected) else {
            return XCTFail("Unchanged editor must still allow caret recovery after navigation")
        }
        XCTAssertEqual(actual.original, conversion.original)
        XCTAssertEqual(actual.replacement, conversion.replacement)
        XCTAssertEqual(actual.expectedSuffix, conversion.expectedSuffix)
        XCTAssertEqual(actual.elementIdentifier, conversion.elementIdentifier)
        XCTAssertEqual(actual.caretLocation, conversion.caretLocation)
        XCTAssertEqual(actual.sourceLayoutID, conversion.sourceLayoutID)
        XCTAssertEqual(actual.targetLayoutID, conversion.targetLayoutID)
    }

    private var conversion: CaretWordConversion {
        CaretWordConversion(original: "abc", replacement: "xyz", expectedSuffix: "abc  ",
            elementIdentifier: "field-a", caretLocation: 7, sourceLayoutID: "en", targetLayoutID: "ru")
    }

    private var outcomes: [CaretWordPreparationOutcome] {
        [.noCandidate, .busy, .blocked(.fieldUnavailable), .conversion(conversion)]
    }

    private func snapshot(
        _ session: InputSession? = nil,
        focus: FocusedElementIdentity = FocusedElementIdentity(
            processID: 123, bundleID: "test.editor", identifier: "field-a"),
        sequence: UInt64 = 0,
        editRevision: UInt64 = 0
    ) -> ManualTokenSnapshot {
        ManualTokenSnapshot(keys: [], boundary: .punctuation(""), focus: focus,
            sequence: session?.sequence ?? sequence, editRevision: session?.editRevision ?? editRevision,
            integrity: session?.integrity ?? .clean)
    }

    private func assertEditorChanged(
        _ outcome: CaretWordPreparationOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .blocked(.editorChanged) = outcome else {
            return XCTFail("Expected .blocked(.editorChanged), got \(outcome)", file: file, line: line)
        }
    }
}
