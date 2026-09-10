import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport
import RuSwitcherTestSupport

@MainActor
final class AutomaticReplacementDriverTests: XCTestCase {
    func testPublicationStagesBeforeEvenAnImmediateAcknowledgement() throws {
        let host = Host()
        host.synchronousVerification = true
        let request = try host.prepare()
        let submission = host.submit(request)
        XCTAssertTrue(submission.handling.stageCompletion)
        XCTAssertEqual(host.layout, "ru")
        XCTAssertEqual(host.confirmations, 0)
        XCTAssertEqual(host.clock.now, 0)
        host.clock.drain()
        XCTAssertEqual(host.confirmations, 1)
        XCTAssertEqual(host.input.context.map(\.text), ["черновик"])
    }

    func testDelayedReadbackCannotUndoANewerLayoutChoice() throws {
        let host = Host()
        _ = host.submit(try host.prepare())
        host.clock.advance(to: 20_000)
        host.layout = "en" // Globe/menu change need not produce a printable key.
        host.clock.drain()
        XCTAssertEqual(host.confirmations, 1)
        XCTAssertEqual(host.layout, "en")
        XCTAssertEqual(host.layoutSwitches, ["ru"])
    }

    func testNewInputBeforeReadbackDoesNotAcquireOldLearning() throws {
        let host = Host()
        _ = host.submit(try host.prepare())
        host.clock.advance(to: 20_000)
        host.input.handle(.printable(.init(keyCode: 9, shift: false, caps: false,
                                          producedText: "м", sourceLayoutID: "ru")))
        let stateBefore = host.input
        host.clock.drain()
        XCTAssertEqual(host.confirmations, 0)
        XCTAssertEqual(host.input, stateBefore)
        XCTAssertEqual(host.completions, [.ignore])
    }

    func testMovingToAnotherFieldCannotConfirmTheOldReplacement() throws {
        let host = Host()
        _ = host.submit(try host.prepare())
        host.focus = .init(processID: 42, bundleID: "test.host", identifier: "other-field")
        host.clock.drain()
        XCTAssertEqual(host.confirmations, 0)
        XCTAssertEqual(host.completions, [.discard])
    }

    func testEditingAndFocusChangeDuringReadbackNeverClearNewerState() throws {
        for event in [InputEvent.plainBackspace, .navigation, .focusChanged, .clipboardCommand, .undo, .tapRecovered] {
            let host = Host()
            _ = host.submit(try host.prepare())
            host.input.handle(event)
            let stateBefore = host.input
            host.clock.drain()
            XCTAssertEqual(host.input, stateBefore)
            XCTAssertEqual(host.confirmations, 0)
            XCTAssertEqual(host.completions, [.ignore])
        }
    }

    func testDuplicateAcknowledgementHasNoSecondLearningOrContext() throws {
        let host = Host()
        host.duplicateAcknowledgement = true
        _ = host.submit(try host.prepare())
        host.clock.drain()
        XCTAssertEqual(host.confirmations, 1)
        XCTAssertEqual(host.completions, [.confirm])
        XCTAssertEqual(host.input.context.count, 1)
    }

    func testDuplicateSubmitDoesNotSwitchOrStageAgain() throws {
        let host = Host()
        let request = try host.prepare()
        _ = host.submit(request)
        let state = host.input
        host.layout = "en"
        let repeated = host.driver.submit(request, sourceLanguage: "en", targetLanguage: "ru",
                                          switchLayout: host.switchLayout) { _ in XCTFail("duplicate callback") }
        XCTAssertEqual(repeated.outcome, .blocked(.duplicateTransaction))
        XCTAssertFalse(repeated.handling.stageCompletion)
        XCTAssertFalse(repeated.handling.finalizeToken)
        XCTAssertEqual(host.layout, "en")
        XCTAssertEqual(host.posts, 1)
        XCTAssertEqual(host.input, state)
    }

    func testUnavailableOrMismatchingReadbackCannotTrain() throws {
        for result in [TextContextValidation.unavailable, .mismatch] {
            let host = Host()
            host.verificationResult = result
            _ = host.submit(try host.prepare())
            host.clock.drain()
            XCTAssertEqual(host.confirmations, 0)
            XCTAssertEqual(host.completions, [result == .unavailable ? .retainUnverified : .invalidate])
        }
    }

    func testRejectedPreflightDoesNotPostOrSwitch() throws {
        let host = Host()
        host.preflight = .mismatch
        let submission = host.submit(try host.prepare())
        host.clock.drain()
        XCTAssertEqual(submission.outcome, .blocked(.expectedSuffixMismatch))
        XCTAssertFalse(submission.handling.consumeBoundary)
        XCTAssertEqual(host.posts, 0)
        XCTAssertEqual(host.layout, "en")
        XCTAssertEqual(host.confirmations, 0)
    }

    func testOldSynchronousResultCannotEraseNewerToken() throws {
        let host = Host()
        let snapshot = try XCTUnwrap(host.prepareSnapshot())
        host.input.handle(.navigation)
        host.input.handle(.printable(.init(keyCode: 0, shift: false, caps: false, producedText: "a")))
        let current = host.input
        XCTAssertFalse(host.input.applyTokenHandlingResult(.passThrough, snapshot: snapshot))
        XCTAssertEqual(host.input, current)
    }
}

@MainActor
private final class Host: FocusedTextContextReading, KeyboardEventPosting {
    let clock = VirtualEventScheduler()
    var input = InputSession()
    var focus = FocusedElementIdentity(processID: 42, bundleID: "test.host", identifier: "field")
    var layout = "en"
    var layoutSwitches: [String?] = []
    var confirmations = 0
    var posts = 0
    var completions: [AutomaticReplacementCompletion] = []
    var synchronousVerification = false
    var duplicateAcknowledgement = false
    var preflight = TextContextValidation.match
    var verificationResult = TextContextValidation.match
    var snapshot: TokenSnapshot?
    lazy var coordinator = NativeReplacementCoordinator(reader: self, poster: self)
    lazy var driver = AutomaticReplacementDriver(coordinator: coordinator, scheduler: clock)

    func prepareSnapshot() -> TokenSnapshot? {
        for character in "xthyjdbr" {
            input.handle(.printable(.init(keyCode: 0, shift: false, caps: false,
                                         producedText: String(character), sourceLayoutID: "en")))
        }
        return input.snapshot(boundary: .space(count: 1), focus: focus)
    }

    func prepare() throws -> ReplacementRequest {
        let snapshot = try XCTUnwrap(prepareSnapshot())
        self.snapshot = snapshot
        XCTAssertTrue(input.beginCommit(expectedRevision: snapshot.editRevision))
        return .init(transaction: .init(original: "xthyjdbr", replacement: "черновик", boundary: snapshot.boundary,
                                       focus: focus, sourceLayoutID: "en", targetLayoutID: "ru",
                                       sequence: snapshot.sequence, editRevision: snapshot.editRevision, automatic: true),
                     deliveredKeyCount: snapshot.deliveredKeyCount, currentFocus: focus, currentRevision: input.editRevision)
    }

    func submit(_ request: ReplacementRequest) -> AutomaticReplacementSubmission {
        let submission = driver.submit(request, sourceLanguage: "en", targetLanguage: "ru",
                                       switchLayout: switchLayout) { [self] outcome in
            let decision = AutomaticReplacementDriver.completion(for: outcome, transaction: request.transaction,
                state: .init(focus: focus, sequence: input.sequence, editRevision: input.editRevision,
                             integrity: input.integrity, hasCurrentToken: !input.currentKeys.isEmpty))
            completions.append(decision)
            if decision == .confirm {
                if input.confirmStagedCompletion(resolvedText: "черновик", language: "ru", wasConverted: true,
                                                 expectedSequence: request.transaction.sequence &+ 1) {
                    confirmations += 1
                }
            } else if decision == .invalidate {
                input.invalidate(clearContext: true)
            }
        }
        if let snapshot { XCTAssertTrue(input.applyTokenHandlingResult(submission.handling, snapshot: snapshot)) }
        return submission
    }

    func switchLayout(_ id: String?) { layoutSwitches.append(id); layout = id ?? layout }

    func validate(expectedSuffix: String, focus: FocusedElementIdentity, deadlineMilliseconds: Int) -> TextContextPreflight {
        switch preflight {
        case .match:
            return TextReplacementAnchor.capture(expectedSuffix: expectedSuffix, focus: focus,
                selection: NSRange(location: expectedSuffix.utf16.count, length: 0),
                capturedRange: NSRange(location: 0, length: expectedSuffix.utf16.count), capturedText: expectedSuffix)
        case .mismatch: return .mismatch
        case .unavailable: return .unavailable
        }
    }

    func verify(expectedSuffix: String, anchor: TextReplacementAnchor, deadlineMilliseconds: Int,
                completion: @escaping @MainActor (TextContextValidation) -> Void) {
        if synchronousVerification { completion(verificationResult); return }
        clock.schedule(at: clock.now + 50_000) { [self] in
            completion(verificationResult)
            if duplicateAcknowledgement { completion(verificationResult) }
        }
    }

    func post(_ plan: EventReplacementPlan, to processID: Int32, delivery: KeyboardEventDelivery) -> Bool {
        posts += 1
        return true
    }
}
