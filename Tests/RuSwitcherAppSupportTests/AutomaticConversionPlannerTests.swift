import Foundation
import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport

final class AutomaticConversionPlannerTests: XCTestCase {
    func testCorrectBothKnownWordsStayLiteralInEnglishPhraseContext() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        var belief = LanguageBelief.neutral
        belief.observe(language: "en")
        belief.observe(language: "en")
        var targetLookups = 0
        func targetLayout() -> String? {
            targetLookups += 1
            return "test.target"
        }

        for (original, converted, current, target) in [
            ("here", "руку", "en", "ru"),
        ] {
            let plan = AutomaticConversionPlanner.prepare(
                snapshot: snapshot(original, context: ["this", "text"], belief: belief),
                original: original, converted: converted,
                currentLanguage: current, targetLanguage: target, targetLayoutID: targetLayout(),
                model: model
            )
            let evaluation = try XCTUnwrap(assertKept(plan, text: original, language: current))
            XCTAssertEqual(evaluation.decision.verdict, .keep, original)
            XCTAssertEqual(evaluation.decision.reason, .blockedContext, original)
            XCTAssertEqual(targetLookups, 0, "Keeping a valid word must not resolve the target layout")
        }
    }

    func testPhysicalPunctuationTailAndUndecidedBoundaryHandling() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        for (original, converted, expected) in [
            ("ghbdtncnde.", "приветствую", "приветствую"),
            ("ghbdtn,", "приветб", "привет,"),
        ] {
            let plan = AutomaticConversionPlanner.prepare(
                snapshot: snapshot(original, context: ["я", "вас"]),
                original: original, converted: converted,
                currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target",
                model: model
            )
            let request = try replacement(in: plan)
            XCTAssertEqual(request.transaction.replacement, expected, original)
            XCTAssertEqual(plan.evaluation?.decision.candidate.replacement, expected, original)
        }

        for (boundary, finalize) in [(InputBoundary.punctuation(","), false), (.space(count: 1), true)] {
            let plan = AutomaticConversionPlanner.prepare(
                snapshot: snapshot("qzx,", boundary: boundary),
                original: "qzx,", converted: "йячб",
                currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target",
                model: model
            )
            let evaluation = try XCTUnwrap(assertKept(plan, text: "qzx,", language: "en", finalize: finalize))
            XCTAssertEqual(evaluation.decision.verdict, .undecided)
        }
    }

    func testSnapshotContextCapsBeliefAndIntegrityReachDecoder() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let englishContext = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("b", context: ["plan"]), original: "b", converted: "и",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target", model: model
        )
        XCTAssertEqual(assertKept(englishContext, text: "b", language: "en")?.decision.verdict, .keep)
        let russianContext = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("b", context: ["это", "план"]), original: "b", converted: "и",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target", model: model
        )
        XCTAssertEqual(try replacement(in: russianContext).transaction.replacement, "и")

        let baseline = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn"), original: "ghbdtn", converted: "привет",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target", model: model
        )
        XCTAssertEqual(try replacement(in: baseline).transaction.replacement, "привет")
        let baselineEvaluation = try XCTUnwrap(baseline.evaluation)
        let caps = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn", capsAt: 2), original: "ghbdtn", converted: "привет",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target", model: model
        )
        let capsEvaluation = try XCTUnwrap(caps.evaluation)
        // One interior Caps Lock key contributes V3's existing literal-score penalty.
        XCTAssertEqual(capsEvaluation.literalScore - baselineEvaluation.literalScore, 1, accuracy: 0.000_001)
        XCTAssertEqual(capsEvaluation.convertedScore, baselineEvaluation.convertedScore, accuracy: 0.000_001)

        var belief = LanguageBelief.neutral
        belief.observe(language: "en")
        belief.observe(language: "en")
        let englishBelief = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn", belief: belief), original: "ghbdtn", converted: "привет",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target", model: model
        )
        XCTAssertGreaterThan(try XCTUnwrap(englishBelief.evaluation).literalScore, baselineEvaluation.literalScore)

        let invalidated = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn", integrity: .invalidated), original: "ghbdtn", converted: "привет",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target",
            policy: .init(neverConvert: [], alwaysConvert: ["привет"]),
            isConfirmed: { _, _ in true }, model: model
        )
        XCTAssertEqual(assertKept(invalidated, text: "ghbdtn", language: "en")?.decision.reason, .blockedEditing)
    }

    func testNeverWinsBeforePrerequisitesAndAlwaysOverridesLexicalKeep() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        var targetLookups = 0
        func targetLayout() -> String? {
            targetLookups += 1
            return "test.target"
        }
        for denied in ["ghbdtn", "привет"] {
            let plan = AutomaticConversionPlanner.prepare(
                snapshot: snapshot("Ghbdtn"), original: "Ghbdtn", converted: "Привет",
                currentLanguage: nil, targetLanguage: nil, targetLayoutID: targetLayout(),
                policy: .init(neverConvert: [denied], alwaysConvert: ["привет"]),
                adaptiveBias: { _, _ in XCTFail("Raw never-match must not query adaptive rules"); return 0 },
                isConfirmed: { _, _ in XCTFail("Raw never-match must not query confirmations"); return false },
                model: nil
            )
            XCTAssertNil(assertKept(plan, text: "Ghbdtn", language: "en"))
            XCTAssertNil(plan.evaluation)
            XCTAssertEqual(targetLookups, 0, "Raw never-match must not resolve the target layout")
        }

        // Neither raw spelling matches; the decoded punctuation candidate is denied.
        let lexicalNever = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn,"), original: "ghbdtn,", converted: "приветб",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: targetLayout(),
            policy: .init(neverConvert: ["привет"], alwaysConvert: ["привет"]), model: model
        )
        XCTAssertEqual(assertKept(lexicalNever, text: "ghbdtn,", language: "en")?.decision.reason, .blockedNever)
        XCTAssertEqual(targetLookups, 0, "A denied decoder candidate must not resolve the target layout")

        let always = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("here", context: ["this", "text"]), original: "here", converted: "руку",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target",
            policy: .init(neverConvert: [], alwaysConvert: ["руку"]),
            adaptiveBias: { _, _ in -20 }, isConfirmed: { _, _ in true }, model: model
        )
        XCTAssertEqual(try replacement(in: always).transaction.replacement, "руку")
        XCTAssertEqual(always.evaluation?.decision.reason, .alwaysConvert)
    }

    func testAdaptiveCallbacksAllowConfirmedPlainAcronymButNotStructuredCode() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let unconfirmed = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ЛЗШ", source: "test.source.ru"), original: "ЛЗШ", converted: "KPI",
            currentLanguage: "ru", targetLanguage: "en", targetLayoutID: "test.target.en", model: model
        )
        XCTAssertEqual(assertKept(unconfirmed, text: "ЛЗШ", language: "ru")?.decision.verdict, .keep)

        var confirmationPairs: [[String]] = []
        var biasPairs: [[String]] = []
        let confirmed = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ЛЗШ", source: "test.source.ru"), original: "ЛЗШ", converted: "KPI",
            currentLanguage: "ru", targetLanguage: "en", targetLayoutID: "test.target.en",
            adaptiveBias: { original, converted in
                biasPairs.append([original, converted])
                return -20
            },
            isConfirmed: { original, converted in
                confirmationPairs.append([original, converted])
                return original == "ЛЗШ" && converted == "KPI"
            }, model: model
        )
        XCTAssertEqual(try replacement(in: confirmed).transaction.replacement, "KPI")
        XCTAssertEqual(confirmed.evaluation?.decision.reason, .confirmedByUser)
        XCTAssertFalse(confirmationPairs.isEmpty)
        XCTAssertFalse(biasPairs.isEmpty)
        XCTAssertTrue(confirmationPairs.allSatisfy { $0 == ["ЛЗШ", "KPI"] })
        XCTAssertTrue(biasPairs.allSatisfy { $0 == ["ЛЗШ", "KPI"] })

        let structured = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("KPI_"), original: "KPI_", converted: "ЛЗШ_",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target",
            isConfirmed: { _, _ in true }, model: model
        )
        XCTAssertEqual(assertKept(structured, text: "KPI_", language: "en")?.decision.reason, .blockedCodeLike)

        let negativeBias = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn"), original: "ghbdtn", converted: "привет",
            currentLanguage: "en", targetLanguage: "ru", targetLayoutID: "test.target",
            adaptiveBias: { original, converted in
                XCTAssertEqual(original, "ghbdtn")
                XCTAssertEqual(converted, "привет")
                return -20
            }, model: model
        )
        XCTAssertEqual(assertKept(negativeBias, text: "ghbdtn", language: "en")?.decision.reason, .blockedLearned)
    }

    func testMissingModelOrLanguagesAndUnsupportedPairDoNotQueryCallbacks() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        var targetLookups = 0
        func targetLayout() -> String? {
            targetLookups += 1
            return "test.target"
        }
        let cases: [(current: String?, target: String?, model: LanguageModelStore?, text: String?, language: String?)] = [
            (nil, "ru", model, nil, nil),
            ("en", nil, model, nil, nil),
            ("en-US", "ru-RU", nil, "ghbdtn", "en-US"),
            ("en-US", "zh-Hans", model, "ghbdtn", "en-US"),
        ]
        for item in cases {
            let plan = AutomaticConversionPlanner.prepare(
                snapshot: snapshot("ghbdtn"), original: "ghbdtn", converted: "привет",
                currentLanguage: item.current, targetLanguage: item.target, targetLayoutID: targetLayout(),
                adaptiveBias: { _, _ in XCTFail("Unavailable decoder must not query adaptive rules"); return 0 },
                isConfirmed: { _, _ in XCTFail("Unavailable decoder must not query confirmations"); return false },
                model: item.model
            )
            XCTAssertNil(assertKept(plan, text: item.text, language: item.language))
            XCTAssertNil(plan.evaluation)
            XCTAssertEqual(targetLookups, 0, "Missing prerequisites must not resolve the target layout")
        }
    }

    func testReplacementRequestPreservesExactTransactionAndUndeliveredSuffix() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let date = Date(timeIntervalSince1970: 200.125)
        var targetLookups = 0
        func targetLayout() -> String? {
            targetLookups += 1
            return "test.target.ru"
        }
        let space = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn,", boundary: .space(count: 2)),
            original: "ghbdtn,", converted: "приветб",
            currentLanguage: "en-US", targetLanguage: "ru-RU", targetLayoutID: targetLayout(),
            model: model, at: date
        )
        XCTAssertEqual(targetLookups, 1)
        let punctuation = AutomaticConversionPlanner.prepare(
            snapshot: snapshot("ghbdtn,", boundary: .punctuation(",")),
            original: "ghbdtn,", converted: "приветб",
            currentLanguage: "en-US", targetLanguage: "ru-RU", targetLayoutID: targetLayout(),
            allowUnavailablePost: true, model: model, at: date
        )
        XCTAssertEqual(targetLookups, 2)
        let cases: [(plan: AutomaticConversionPlan, boundary: InputBoundary, suffix: String, delivered: Int, axless: Bool)] = [
            (space, .space(count: 2), "ghbdtn,", 7, false),
            (punctuation, .punctuation(","), "ghbdtn", 6, true),
        ]
        for item in cases {
            let request = try replacement(in: item.plan)
            let expectedFocus = FocusedElementIdentity(processID: 4242, bundleID: "test.host", identifier: "field-9")
            XCTAssertEqual(request.transaction, ConversionTransaction(
                original: "ghbdtn,", replacement: "привет,", boundary: item.boundary,
                focus: expectedFocus, sourceLayoutID: "test.source.en", targetLayoutID: "test.target.ru",
                sequence: 73, editRevision: 19, expectedOriginalSuffix: item.suffix,
                createdAt: Date(timeIntervalSince1970: 200.125), automatic: true
            ))
            XCTAssertEqual(request.currentFocus, expectedFocus)
            XCTAssertEqual(request.currentRevision, 19)
            XCTAssertEqual(request.deliveredKeyCount, item.delivered)
            XCTAssertEqual(request.allowUnavailablePost, item.axless)
        }
    }

    private func snapshot(
        _ text: String,
        boundary: InputBoundary = .space(count: 1),
        context: [String] = [],
        belief: LanguageBelief = .neutral,
        capsAt: Int? = nil,
        integrity: EditorIntegrity = .clean,
        source: String = "test.source.en"
    ) -> TokenSnapshot {
        TokenSnapshot(
            keys: text.enumerated().map { index, character in
                TypedKey(keyCode: 0, shift: capsAt == index, caps: capsAt == index,
                         producedText: String(character), sourceLayoutID: source)
            },
            context: context.map { InputContextToken(text: $0) },
            boundary: boundary,
            focus: .init(processID: 4242, bundleID: "test.host", identifier: "field-9"),
            sequence: 73, capturedAt: Date(timeIntervalSince1970: 100),
            languageBelief: belief, editRevision: 19, integrity: integrity
        )
    }

    @discardableResult
    private func assertKept(
        _ plan: AutomaticConversionPlan,
        text: String?,
        language: String?,
        finalize: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> LayoutDecoderEvaluation? {
        guard case let .keep(handling, evaluation) = plan else {
            XCTFail("Expected keep plan without a replacement request", file: file, line: line)
            return nil
        }
        XCTAssertEqual(handling, TokenHandlingResult(
            consumeBoundary: false, finalizeToken: finalize, resolvedText: text,
            resolvedLanguage: language, wasConverted: false
        ), file: file, line: line)
        XCTAssertEqual(plan.evaluation, evaluation, file: file, line: line)
        return evaluation
    }

    private func replacement(
        in plan: AutomaticConversionPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ReplacementRequest {
        var request: ReplacementRequest?
        if case let .replace(value, evaluation) = plan {
            request = value
            XCTAssertEqual(evaluation.decision.verdict, .switchToConverted, file: file, line: line)
            XCTAssertEqual(plan.evaluation, evaluation, file: file, line: line)
        }
        return try XCTUnwrap(request, "Expected replacement plan", file: file, line: line)
    }
}
