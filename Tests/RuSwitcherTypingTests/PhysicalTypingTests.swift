import XCTest
import RuSwitcherCore
import RuSwitcherTestSupport

@MainActor
final class PhysicalTypingTests: XCTestCase {
    private let en = "com.apple.keylayout.US"
    private let ru = "com.apple.keylayout.RussianWin"

    // These are independently authored expectations, not decoder-generated text.
    private let russianPhrase = "сегодня мы обсудим проект, а завтра отправим письмо. "
    private let englishPhrase = "please send the document to the office, and keep a copy. "

    func testNativeLayoutPunctuationAgainstIndependentGoldenKeys() throws {
        let layouts = try systemLayouts()
        let cases: [(UInt16, Bool, String, String)] = [
            (43, false, ",", "б"), (47, false, ".", "ю"),
            (26, true, "&", "?"), (44, true, "?", ","),
            (3, false, "f", "а"), (11, true, "B", "И"),
        ]
        for (key, shift, english, russian) in cases {
            XCTAssertEqual(try layouts.character(keyCode: key, shift: shift, layoutID: en), english)
            XCTAssertEqual(try layouts.character(keyCode: key, shift: shift, layoutID: ru), russian)
        }
        XCTAssertEqual(try layouts.character(keyCode: 3, shift: false, capsLock: true, layoutID: en), "F")
        XCTAssertEqual(try layouts.character(keyCode: 3, shift: false, capsLock: true, layoutID: ru), "А")
    }

    func testContinuousPhrasesFollowActualSwitchWithoutPerWordLayoutCommands() throws {
        let layouts = try systemLayouts()
        let runner = try makeRunner(layouts)
        for (text, intended, initial) in [(russianPhrase, ru, en), (englishPhrase, en, ru)] {
            let fixture = try phrase(text, intended: intended, initial: initial, layouts: layouts, transactions: 1)
            XCTAssertFalse(fixture.stimulus.actions.contains { $0.kind == .selectLayout })
            let execution = try runner.run(fixture.stimulus)
            XCTAssertEqual(execution.text, text, String(describing: execution.decisions))
            XCTAssertEqual(execution.transactions, 1)
            XCTAssertTrue(PhysicalTypingAssessment.assess(execution, oracle: fixture.oracle).passed)
        }
    }

    func testCorrectProseAndProtectedPunctuationAreNotChanged() throws {
        let layouts = try systemLayouts()
        let runner = try makeRunner(layouts)
        for (text, language) in [
            ("we chose option B, but kept room A. email qa@example.org! ", en),
            ("он спросил: \"ты в офисе?\" мы ответили: \"да, но позже...\" ", ru),
        ] {
            let fixture = try phrase(text, intended: language, initial: language, layouts: layouts, transactions: 0)
            let execution = try runner.run(fixture.stimulus)
            XCTAssertEqual(execution.text, text)
            XCTAssertTrue(PhysicalTypingAssessment.assess(execution, oracle: fixture.oracle).passed)
        }
    }

    func testPunctuationOnTheFirstWrongLayoutWordInBothDirections() throws {
        let layouts = try systemLayouts()
        let runner = try makeRunner(layouts)
        for (text, intended, initial) in [
            ("сегодня? да, после работы! ", ru, en),
            ("please, send the draft; we need it today! ", en, ru),
        ] {
            let fixture = try phrase(text, intended: intended, initial: initial, layouts: layouts, transactions: 1)
            let execution = try runner.run(fixture.stimulus)
            XCTAssertEqual(execution.text, text, String(describing: execution.decisions))
            XCTAssertTrue(PhysicalTypingAssessment.assess(execution, oracle: fixture.oracle).passed)
        }
    }

    func testUnsupportedAutomaticDeadKeyCompositionCannotClaimSuccess() throws {
        let international = "com.apple.keylayout.USInternational-PC"
        let layouts: SystemTypingLayouts
        do { layouts = try SystemTypingLayouts(ids: [international, ru]) }
        catch PhysicalTypingError.unavailableLayout(let id) { throw XCTSkip("Required system layout unavailable: \(id)") }
        let stimulus = PhysicalTypingStimulus(id: "dead-key-contract", layoutIDs: [international, ru],
                                             initialLayoutID: international, actions: [
            .init(kind: .keyDown, atMicroseconds: 0, keyCode: 39, shift: true),
            .init(kind: .keyUp, atMicroseconds: 1, keyCode: 39, shift: true),
            .init(kind: .keyDown, atMicroseconds: 2, keyCode: 49),
            .init(kind: .keyUp, atMicroseconds: 3, keyCode: 49),
        ])
        let runner = try makeRunner(layouts)
        XCTAssertThrowsError(try runner.run(stimulus)) { error in
            XCTAssertEqual(error as? PhysicalTypingError, .unsupportedAction(0, "automatic dead-key composition"))
        }
        var faults = PhysicalTypingFaults()
        faults.disableAutomaticConversion = true
        XCTAssertEqual(try runner.run(stimulus, faults: faults).text, "\"")
    }

    func testBrokenLayoutSwitchIsVisibleAtTheNextPhysicalKey() throws {
        let layouts = try systemLayouts()
        let fixture = try phrase(russianPhrase, intended: ru, initial: en, layouts: layouts, transactions: 1)
        var faults = PhysicalTypingFaults()
        faults.disableLayoutSwitch = true
        let broken = try makeRunner(layouts).run(fixture.stimulus, faults: faults)
        let nextKey = try XCTUnwrap(fixture.oracle.checkpoints.first).actionIndex
        // The first correction succeeds. Inspect BEFORE the next word can be
        // rescued by another correction, which final-text-only tests can miss.
        XCTAssertEqual(broken.observations[nextKey - 1].textAfter, "сегодня ")
        XCTAssertEqual(broken.observations[nextKey].producedText, "v")
        XCTAssertEqual(broken.observations[nextKey].layoutIDBefore, en)
        let assessment = PhysicalTypingAssessment.assess(broken, oracle: fixture.oracle)
        XCTAssertFalse(assessment.passed)
        XCTAssertTrue(assessment.failures.contains("checkpoint-layout-mismatch-\(nextKey)"))
    }

    func testAutomaticOffDroppedAndDuplicateInsertionCannotPass() throws {
        let layouts = try systemLayouts()
        let fixture = try phrase(russianPhrase, intended: ru, initial: en, layouts: layouts, transactions: 1)
        let runner = try makeRunner(layouts)
        var automaticOff = PhysicalTypingFaults()
        automaticOff.disableAutomaticConversion = true
        var dropped = PhysicalTypingFaults()
        dropped.dropInsertion = true
        var duplicated = PhysicalTypingFaults()
        duplicated.duplicateInsertion = true
        for faults in [automaticOff, dropped, duplicated] {
            let execution = try runner.run(fixture.stimulus, faults: faults)
            XCTAssertNotEqual(execution.text, fixture.oracle.text)
            XCTAssertFalse(PhysicalTypingAssessment.assess(execution, oracle: fixture.oracle).passed)
        }
    }

    func testOracleCannotInfluenceExecution() throws {
        let layouts = try systemLayouts()
        let fixture = try phrase(russianPhrase, intended: ru, initial: en, layouts: layouts, transactions: 1)
        let runner = try makeRunner(layouts)
        let execution = try runner.run(fixture.stimulus)
        let wrongOracle = PhysicalTypingOracle(text: "incorrect", finalLayoutID: en, transactions: 999)
        XCTAssertFalse(PhysicalTypingAssessment.assess(execution, oracle: wrongOracle).passed)
        XCTAssertEqual(try runner.run(fixture.stimulus), execution)
        XCTAssertTrue(PhysicalTypingAssessment.assess(execution, oracle: fixture.oracle).passed)
    }

    func testMixedLanguagePhraseUsesOnlyExplicitUserLayoutChanges() throws {
        let layouts = try systemLayouts()
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: "сегодня мы отправим ", intendedLayoutID: ru)
        try compiler.selectLayout(en)
        try compiler.append(text: "the final draft, ", intendedLayoutID: en)
        try compiler.selectLayout(ru)
        try compiler.append(text: "а завтра обсудим детали. ", intendedLayoutID: ru)
        let stimulus = PhysicalTypingStimulus(id: "mixed-draft", layoutIDs: [en, ru], initialLayoutID: en, actions: compiler.actions)
        let oracle = PhysicalTypingOracle(
            text: "сегодня мы отправим the final draft, а завтра обсудим детали. ",
            finalLayoutID: ru, transactions: 1
        )
        let execution = try makeRunner(layouts).run(stimulus)
        XCTAssertEqual(execution.text, oracle.text)
        XCTAssertTrue(PhysicalTypingAssessment.assess(execution, oracle: oracle).passed)
    }

    func testBackspaceAutorepeatToZeroThenSpaceAndNewPhrase() throws {
        let layouts = try systemLayouts()
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: "we keep ", intendedLayoutID: en)
        let offset = try XCTUnwrap(compiler.actions.last).atMicroseconds + 1
        let editing: [PhysicalTypingAction] = [
            .init(kind: .keyDown, atMicroseconds: offset, keyCode: 0),
            .init(kind: .keyUp, atMicroseconds: offset + 1, keyCode: 0),
            .init(kind: .keyDown, atMicroseconds: offset + 2, keyCode: 11),
            .init(kind: .keyUp, atMicroseconds: offset + 3, keyCode: 11),
            .init(kind: .keyDown, atMicroseconds: offset + 4, keyCode: 51),
            .init(kind: .keyDown, atMicroseconds: offset + 5, keyCode: 51, autorepeat: true),
            .init(kind: .keyUp, atMicroseconds: offset + 6, keyCode: 51),
        ]
        var tail = PhysicalTypingCompiler(layouts: layouts)
        try tail.append(text: " the final draft. ", intendedLayoutID: en)
        let shifted = tail.actions.map {
            PhysicalTypingAction(kind: $0.kind, atMicroseconds: $0.atMicroseconds + offset + 7,
                                 keyCode: $0.keyCode, shift: $0.shift)
        }
        let stimulus = PhysicalTypingStimulus(id: "delete-resume", layoutIDs: [en, ru], initialLayoutID: en,
                                             actions: compiler.actions + editing + shifted)
        let execution = try makeRunner(layouts).run(stimulus)
        XCTAssertEqual(execution.text, "we keep  the final draft. ")
        XCTAssertEqual(execution.transactions, 0)
    }

    func testMalformedEventsAndUnsupportedTextFailExplicitly() throws {
        let layouts = try systemLayouts()
        let runner = try makeRunner(layouts)
        for actions: [PhysicalTypingAction] in [
            [.init(kind: .keyUp, atMicroseconds: 0, keyCode: 0)],
            [.init(kind: .keyDown, atMicroseconds: 0, keyCode: 0)],
            [.init(kind: .keyDown, atMicroseconds: 0, keyCode: 123)],
            [.init(kind: .selectLayout, atMicroseconds: 0, layoutID: "not-a-layout")],
        ] {
            let stimulus = PhysicalTypingStimulus(id: "invalid", layoutIDs: [en, ru], initialLayoutID: en, actions: actions)
            XCTAssertThrowsError(try runner.run(stimulus))
        }
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        XCTAssertThrowsError(try compiler.append(text: "🙂", intendedLayoutID: en))
        XCTAssertTrue(compiler.actions.isEmpty, "Unmappable characters must not silently become keycode zero")
    }

    private func systemLayouts() throws -> SystemTypingLayouts {
        do { return try SystemTypingLayouts(ids: [en, ru]) }
        catch PhysicalTypingError.unavailableLayout(let id) { throw XCTSkip("Required system layout unavailable: \(id)") }
    }

    private func makeRunner(_ layouts: SystemTypingLayouts) throws -> PhysicalTypingRunner {
        PhysicalTypingRunner(layouts: layouts, model: try XCTUnwrap(LanguageModelStore.bundled))
    }

    private func phrase(_ text: String, intended: String, initial: String, layouts: SystemTypingLayouts,
                        transactions: Int) throws -> PhysicalTypingFixture {
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: text, intendedLayoutID: intended)
        let firstSpace = try XCTUnwrap(compiler.actions.firstIndex { $0.kind == .keyUp && $0.keyCode == 49 })
        return PhysicalTypingFixture(
            stimulus: .init(id: "continuous-\(intended)", layoutIDs: [en, ru], initialLayoutID: initial, actions: compiler.actions),
            oracle: .init(text: text, finalLayoutID: intended, transactions: transactions,
                          checkpoints: [.init(actionIndex: firstSpace + 1, layoutIDBefore: intended)])
        )
    }
}
