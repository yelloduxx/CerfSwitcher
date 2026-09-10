import XCTest
import RuSwitcherCore
import RuSwitcherTestSupport

@MainActor
final class ScheduledPhysicalTypingTests: XCTestCase {
    private let en = "com.apple.keylayout.US"
    private let ru = "com.apple.keylayout.RussianWin"
    private let prose = "сегодня мы подготовим письмо, а завтра обсудим детали! "

    func testContinuousProseWithIndependentReadbackDelaysAndNoWordPauses() throws {
        let layouts = try layouts()
        let runner = try runner(layouts)
        for delay: UInt64 in [0, 1_000, 4_000, 16_000, 50_000, 120_000, 250_000] {
            var timing = PhysicalTypingTiming()
            timing.deliveryDelayMicroseconds = 1_000
            timing.syntheticEventIntervalMicroseconds = 50
            timing.verificationReadDelayMicroseconds = delay
            let fixture = try phrase(layouts, timing: timing)
            let actual = try runner.run(fixture.stimulus)
            XCTAssertTrue(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed, "delay=\(delay)")
            XCTAssertEqual(actual.editors["editor"]?.selectedRange, NSRange(location: prose.utf16.count, length: 0))
            XCTAssertEqual(actual.transactions, 1)
            XCTAssertEqual(actual.trace.filter { $0.event == "layout-delivered" }.count, 1)
            if delay > 120_000 { XCTAssertTrue(actual.trace.contains { $0.event == "readback-timeout" }) }
        }
    }

    func testFastTypingSupersedesDelayedConfirmationWithoutChangingTheNewToken() throws {
        let layouts = try layouts()
        var timing = PhysicalTypingTiming()
        timing.verificationReadDelayMicroseconds = 0
        timing.acknowledgementDelayMicroseconds = 50_000
        let fixture = try phrase(layouts, timing: timing, interval: 1_000)
        let actual = try runner(layouts).run(fixture.stimulus)
        XCTAssertTrue(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed)
        XCTAssertEqual(actual.verifiedCompletions, 0)
        XCTAssertTrue(actual.trace.contains { $0.event == "completion-ignore" })
        XCTAssertEqual(actual.context, prose.split(separator: " ").map(String.init))
    }

    func testLateConfirmationDoesNotReverseAnExplicitLayoutChoice() throws {
        let layouts = try layouts()
        var timing = PhysicalTypingTiming()
        timing.acknowledgementDelayMicroseconds = 50_000
        let original = try phrase(layouts, timing: timing)
        let boundary = try XCTUnwrap(original.stimulus.actions.firstIndex { $0.kind == .keyDown && $0.keyCode == 49 })
        // Keep only the opening word, then explicitly change input source after
        // read-back but before acknowledgement. No new key invalidates staging.
        var actions = Array(original.stimulus.actions.prefix(boundary + 2))
        actions.append(.init(kind: .selectLayout, atMicroseconds: try XCTUnwrap(actions.last).atMicroseconds + 1, layoutID: en))
        let stimulus = PhysicalTypingStimulus(id: "late-source-choice", layoutIDs: [en, ru], initialLayoutID: en,
                                             actions: actions, timing: timing)
        let actual = try runner(layouts).run(stimulus)
        XCTAssertEqual(actual.text, "сегодня ")
        XCTAssertEqual(actual.verifiedCompletions, 1)
        XCTAssertEqual(actual.finalLayoutID, en)
        XCTAssertEqual(actual.trace.filter { $0.event == "layout-delivered" }.count, 1)
    }

    func testAnotherFieldCannotReceiveOldContextOrConfirmation() throws {
        let layouts = try layouts()
        var timing = PhysicalTypingTiming()
        timing.acknowledgementDelayMicroseconds = 50_000
        let original = try phrase(layouts, timing: timing)
        let boundary = try XCTUnwrap(original.stimulus.actions.firstIndex { $0.kind == .keyDown && $0.keyCode == 49 })
        var actions = Array(original.stimulus.actions.prefix(boundary + 2))
        let at = try XCTUnwrap(actions.last).atMicroseconds + 1
        actions.append(.init(kind: .focusChange, atMicroseconds: at, fieldID: "second"))
        let stimulus = PhysicalTypingStimulus(id: "different-field", layoutIDs: [en, ru], initialLayoutID: en,
                                             actions: actions, timing: timing)
        let actual = try runner(layouts).run(stimulus)
        XCTAssertEqual(actual.editors["editor"]?.text, "сегодня ")
        XCTAssertEqual(actual.editors["second"]?.text, "")
        XCTAssertEqual(actual.context, [])
        XCTAssertEqual(actual.verifiedCompletions, 0)
        XCTAssertTrue(actual.trace.contains { $0.event == "completion-discard" })
    }

    func testTapRecoveryDiscardsOldStateWithoutErasingEditorText() throws {
        let layouts = try layouts()
        let original = try phrase(layouts)
        let boundary = try XCTUnwrap(original.stimulus.actions.firstIndex { $0.kind == .keyDown && $0.keyCode == 49 })
        var actions = original.stimulus.actions
        actions.insert(.init(kind: .tapRecovery, atMicroseconds: actions[boundary].atMicroseconds + 500), at: boundary + 1)
        let stimulus = PhysicalTypingStimulus(id: "tap-recovered", layoutIDs: [en, ru], initialLayoutID: en, actions: actions)
        let actual = try runner(layouts).run(stimulus)
        XCTAssertEqual(actual.text, prose)
        XCTAssertEqual(actual.verifiedCompletions, 0)
        XCTAssertTrue(actual.trace.contains { $0.event == "completion-ignore" })
        XCTAssertFalse(actual.context.contains("сегодня"))
    }

    func testDroppedBackspaceAndDuplicateInsertionCannotReceiveAnchoredConfirmation() throws {
        let layouts = try layouts()
        let fixture = try phrase(layouts)
        var dropped = PhysicalTypingFaults()
        dropped.dropFirstBackspace = true
        var duplicated = PhysicalTypingFaults()
        duplicated.duplicateInsertion = true
        for faults in [dropped, duplicated] {
            let actual = try runner(layouts).run(fixture.stimulus, faults: faults)
            XCTAssertFalse(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed)
            XCTAssertNotEqual(actual.text, fixture.oracle.text)
            // Damage is observable, not destructively retried or accepted as a
            // verified edit. Detection is not a claim that the text was repaired.
            XCTAssertEqual(actual.verifiedCompletions, 0)
            XCTAssertFalse(actual.trace.contains { $0.event == "completion-confirm" })
        }
    }

    func testAcceptedButUndeliveredInsertionCannotPassTheOracle() throws {
        let layouts = try layouts()
        let fixture = try phrase(layouts)
        var faults = PhysicalTypingFaults()
        faults.dropInsertion = true
        let actual = try runner(layouts).run(fixture.stimulus, faults: faults)
        XCTAssertEqual(actual.transactions, 1)
        XCTAssertEqual(actual.verifiedCompletions, 0)
        XCTAssertFalse(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed)
        XCTAssertTrue(actual.trace.contains { $0.event == "synthetic-insertion-dropped" })
    }

    func testSlowDeliveryOverlappingTheNextWordIsVisibleRatherThanSerializedAway() throws {
        let layouts = try layouts()
        var timing = PhysicalTypingTiming()
        timing.deliveryDelayMicroseconds = 16_000
        timing.syntheticEventIntervalMicroseconds = 100
        let fixture = try phrase(layouts, timing: timing, interval: 1_000)
        let actual = try runner(layouts).run(fixture.stimulus)
        XCTAssertFalse(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed)
        let submitted = try XCTUnwrap(actual.trace.first { $0.event == "submit-postedUnverified" })
        let deletion = try XCTUnwrap(actual.trace.first { $0.event == "synthetic-backspace" })
        XCTAssertTrue(actual.observations.contains {
            $0.atMicroseconds > submitted.atMicroseconds && $0.atMicroseconds < deletion.atMicroseconds && !$0.producedText.isEmpty
        })
        XCTAssertGreaterThan(deletion.inputSequence, submitted.inputSequence)
        XCTAssertEqual(actual.verifiedCompletions, 0)
    }

    func testSyntheticEventsDoNotFeedTheSessionAndDuplicateAckDoesNotAppendContextTwice() throws {
        let layouts = try layouts()
        let fixture = try phrase(layouts)
        var faults = PhysicalTypingFaults()
        faults.duplicateAcknowledgement = true
        let actual = try runner(layouts).run(fixture.stimulus, faults: faults)
        XCTAssertTrue(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed)
        XCTAssertEqual(actual.verifiedCompletions, 1)
        XCTAssertEqual(actual.context.filter { $0 == "сегодня" }.count, 1)
        let synthetic = actual.trace.filter { $0.event.hasPrefix("synthetic-") }
        XCTAssertEqual(Set(synthetic.map(\.inputSequence)).count, 1)
        XCTAssertEqual(Set(synthetic.map(\.editRevision)).count, 1)
        XCTAssertGreaterThan(Set(synthetic.map { $0.editor.revision }).count, 1)
    }

    func testNavigationSelectionAndTypingUseTheSameClassifier() throws {
        let layouts = try layouts()
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: "we keep the draft", intendedLayoutID: en)
        var actions = compiler.actions
        var at = try XCTUnwrap(actions.last).atMicroseconds + 1
        for _ in 0..<5 {
            actions.append(.init(kind: .keyDown, atMicroseconds: at, keyCode: 123, shift: true))
            actions.append(.init(kind: .keyUp, atMicroseconds: at + 1, keyCode: 123, shift: true))
            at += 2
        }
        var replacement = PhysicalTypingCompiler(layouts: layouts)
        try replacement.append(text: "note, and send it. ", intendedLayoutID: en)
        actions += replacement.actions.map {
            .init(kind: $0.kind, atMicroseconds: at + $0.atMicroseconds, keyCode: $0.keyCode, shift: $0.shift)
        }
        let actual = try runner(layouts).run(.init(id: "selection-typing", layoutIDs: [en, ru], initialLayoutID: en, actions: actions))
        XCTAssertEqual(actual.text, "we keep the note, and send it. ")
        XCTAssertEqual(actual.transactions, 0)
        XCTAssertEqual(actual.editors["editor"]?.selectedRange.length, 0)
        XCTAssertFalse(actual.context.contains("draft"))
    }

    func testScheduledExecutionIsReproducibleAndContextCapacityMatchesProduction() throws {
        let layouts = try layouts()
        var timing = PhysicalTypingTiming()
        timing.syntheticEventIntervalMicroseconds = 100
        timing.acknowledgementDelayMicroseconds = 16_000
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        let text = "we will send the final draft to the office in the morning, and then we will discuss the next steps together. "
        try compiler.append(text: text, intendedLayoutID: en, intervalMicroseconds: 4_000)
        let stimulus = PhysicalTypingStimulus(id: "stable-schedule", layoutIDs: [en, ru], initialLayoutID: en,
                                             actions: compiler.actions, timing: timing)
        let runner = try runner(layouts)
        let first = try runner.run(stimulus)
        XCTAssertEqual(first, try runner.run(stimulus))
        XCTAssertEqual(first.text, text)
        XCTAssertEqual(first.context.count, InputContextLimits.maximumTokens)
    }

    func testIndependentOracleRejectsWrongCaretAndConfirmationCounts() throws {
        let layouts = try layouts()
        let fixture = try phrase(layouts)
        let actual = try runner(layouts).run(fixture.stimulus)
        let wrong = PhysicalTypingOracle(text: actual.text, finalLayoutID: ru, transactions: 1,
                                         selectedRange: NSRange(location: 0, length: 0), verifiedCompletions: 2)
        let result = PhysicalTypingAssessment.assess(actual, oracle: wrong)
        XCTAssertEqual(result.failures, ["selection-mismatch", "verified-completion-count-mismatch"])
    }

    func testQueuedNextLetterReproducesBothNativeLayoutDirectionsWithoutWaitingForTheWord() throws {
        let layouts = try layouts()
        let runner = try runner(layouts)
        for (text, intended, initial) in [(prose, ru, en),
                                          ("please review the memo, and keep plan B for tomorrow. ", en, ru)] {
            for prePost: UInt64 in [1_000, 6_000] {
                var timing = PhysicalTypingTiming()
                timing.conversionPrePostMicroseconds = prePost
                timing.conversionPostWorkMicroseconds = 8_000
                timing.deliveryDelayMicroseconds = 1_000
                timing.syntheticEventIntervalMicroseconds = 50
                timing.verificationReadDelayMicroseconds = 20_000
                let fixture = try rollingOpening(layouts, text: text, intended: intended, initial: initial, timing: timing)
                let fixed = try runner.run(fixture.stimulus)
                XCTAssertTrue(PhysicalTypingAssessment.assess(fixed, oracle: fixture.oracle).passed)
                var oldBehavior = PhysicalTypingFaults()
                oldBehavior.disableQueuedLayoutSynchronization = true
                let broken = try runner.run(fixture.stimulus, faults: oldBehavior)
                XCTAssertFalse(PhysicalTypingAssessment.assess(broken, oracle: fixture.oracle).passed)
                XCTAssertEqual(broken.transactions, fixed.transactions)
                let waitingKey = try XCTUnwrap(fixed.observations.first {
                    !$0.producedText.isEmpty && $0.capturedLayoutID != $0.layoutIDBefore
                })
                XCTAssertGreaterThan(waitingKey.processedAtMicroseconds, waitingKey.atMicroseconds)
                XCTAssertNotEqual(waitingKey.capturedText, waitingKey.producedText)
                XCTAssertEqual(waitingKey.deliveredText, waitingKey.producedText)
                XCTAssertEqual(broken.observations[waitingKey.actionIndex].deliveredText, waitingKey.capturedText)
                let start = try XCTUnwrap(fixed.trace.first { $0.event == "submit-postedUnverified" })
                let end = try XCTUnwrap(fixed.trace.first {
                    $0.event == "callback-ended" && $0.actionIndex == start.actionIndex
                })
                XCTAssertTrue(fixed.trace.contains {
                    $0.event == "synthetic-insertion" && $0.atMicroseconds > start.atMicroseconds && $0.atMicroseconds < end.atMicroseconds
                })
                XCTAssertEqual(fixed.verifiedCompletions, 0)
            }
        }
    }

    func testBusyCallbackDoesNotHideDeliveryThatArrivesAfterItHasReturned() throws {
        let layouts = try layouts()
        var timing = PhysicalTypingTiming()
        timing.conversionPrePostMicroseconds = 2_000
        timing.conversionPostWorkMicroseconds = 8_000
        timing.deliveryDelayMicroseconds = 30_000
        let fixture = try rollingOpening(layouts, text: prose, intended: ru, initial: en, timing: timing)
        let actual = try runner(layouts).run(fixture.stimulus)
        XCTAssertFalse(PhysicalTypingAssessment.assess(actual, oracle: fixture.oracle).passed)
        XCTAssertEqual(actual.verifiedCompletions, 0)
        let firstDeletion = try XCTUnwrap(actual.trace.first { $0.event == "synthetic-backspace" })
        let queuedLetter = try XCTUnwrap(actual.observations.first { $0.capturedLayoutID != $0.layoutIDBefore })
        XCTAssertLessThan(queuedLetter.processedAtMicroseconds, firstDeletion.atMicroseconds)
    }

    private func rollingOpening(_ layouts: SystemTypingLayouts, text: String, intended: String, initial: String,
                                timing: PhysicalTypingTiming) throws -> PhysicalTypingFixture {
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: text, intendedLayoutID: intended, intervalMicroseconds: 70_000)
        let boundary = try XCTUnwrap(compiler.actions.firstIndex { $0.kind == .keyDown && $0.keyCode == 49 })
        let next = try XCTUnwrap(compiler.actions.indices.first { $0 > boundary && compiler.actions[$0].kind == .keyDown })
        let shift = compiler.actions[next].atMicroseconds - compiler.actions[boundary].atMicroseconds - 5_000
        let actions: [PhysicalTypingAction] = compiler.actions.enumerated().map { index, action in
            .init(kind: action.kind, atMicroseconds: action.atMicroseconds - (index >= next ? shift : 0),
                  keyCode: action.keyCode, shift: action.shift, capsLock: action.capsLock)
        }.sorted { $0.atMicroseconds < $1.atMicroseconds }
        return .init(stimulus: .init(id: "queued-opening", layoutIDs: [en, ru], initialLayoutID: initial,
                                     actions: actions, timing: timing),
                     oracle: .init(text: text, finalLayoutID: intended, transactions: 1))
    }

    private func layouts() throws -> SystemTypingLayouts {
        do { return try SystemTypingLayouts(ids: [en, ru]) }
        catch PhysicalTypingError.unavailableLayout(let id) { throw XCTSkip("Required system layout unavailable: \(id)") }
    }

    private func runner(_ layouts: SystemTypingLayouts) throws -> PhysicalTypingRunner {
        .init(layouts: layouts, model: try XCTUnwrap(LanguageModelStore.bundled))
    }

    private func phrase(_ layouts: SystemTypingLayouts, timing: PhysicalTypingTiming = .init(), interval: UInt64 = 70_000) throws -> PhysicalTypingFixture {
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: prose, intendedLayoutID: ru, intervalMicroseconds: interval)
        return .init(stimulus: .init(id: "scheduled-prose", layoutIDs: [en, ru], initialLayoutID: en,
                                    actions: compiler.actions, timing: timing),
                     oracle: .init(text: prose, finalLayoutID: ru, transactions: 1))
    }
}
