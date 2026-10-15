import XCTest
@testable import RuSwitcherCore

final class ManualLearningPolicyTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    func testKnownWordToUnknownKeyboardStringIsRejected() {
        XCTAssertTrue(ManualLearningPolicy.isLikelyReverseConversion(
            original: "привет",
            converted: "ghbdtn",
            model: model
        ))
        XCTAssertFalse(ManualLearningPolicy.shouldPersist(
            original: "привет",
            converted: "ghbdtn",
            model: model
        ))
    }

    func testUnknownKeyboardStringToKnownWordCanBeLearned() {
        XCTAssertFalse(ManualLearningPolicy.isLikelyReverseConversion(
            original: "ghbdtn",
            converted: "привет",
            model: model
        ))
        XCTAssertTrue(ManualLearningPolicy.shouldPersist(
            original: "ghbdtn",
            converted: "привет",
            model: model
        ))
    }

    func testBothKnownAmbiguousPairRemainsExplicitlyLearnable() {
        XCTAssertTrue(ManualLearningPolicy.shouldPersist(
            original: "here",
            converted: "руку",
            model: model
        ))
    }

    func testPlainUppercaseLayoutPairCanBeLearned() {
        XCTAssertTrue(ManualLearningPolicy.shouldPersist(
            original: "ЫУЩ",
            converted: "SEO",
            model: model
        ))
    }

    func testStructuredUppercaseIdentifiersRemainUnlearnable() {
        for pair in [("ЫУЩ_", "SEO_"), ("ЫУЩ.com", "SEO.com")] {
            XCTAssertFalse(ManualLearningPolicy.shouldPersist(
                original: pair.0,
                converted: pair.1,
                model: model
            ))
        }
    }

    func testReversingAnExistingGlobalRuleCreatesOnlyAnApplicationException() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "cnhfybwf", converted: "страница")
        // The old dictionary-only gate rejects this direction before the rule
        // book gets a chance to record the user's application exception.
        XCTAssertFalse(ManualLearningPolicy.shouldPersist(original: "страница", converted: "cnhfybwf", model: model))
        let decision = ManualLearningPolicy.decision(original: "страница ", converted: "cnhfybwf ",
                                                     appBundleID: "editor.second", ruleBook: book, model: model)
        XCTAssertEqual(decision, .applicationException(original: "cnhfybwf", converted: "страница", appBundleID: "editor.second"))
        decision.apply(to: &book)
        XCTAssertFalse(book.isConfirmed(original: "cnhfybwf", converted: "страница", appBundleID: "editor.second"))
        XCTAssertTrue(book.isConfirmed(original: "cnhfybwf", converted: "страница", appBundleID: "editor.first"))
        XCTAssertFalse(book.rules.contains { $0.original == "страница" && $0.converted == "cnhfybwf" })
        let reaffirmed = ManualLearningPolicy.decision(original: "cnhfybwf ", converted: "страница ",
                                                       appBundleID: "editor.second", ruleBook: book, model: model)
        reaffirmed.apply(to: &book)
        XCTAssertTrue(book.isConfirmed(original: "cnhfybwf", converted: "страница", appBundleID: "editor.second"))
    }

    func testConvertingIntoARealWordReplacesTheOppositeLearnedPair() {
        XCTAssertTrue(model.contains("сука", language: "ru") || model.isExtendedRussianWord("сука"))
        for (old, new) in [(("руку", "here"), ("here", "руку")), (("привет", "ghbdtn"), ("ghbdtn", "привет")),
                           (("сука", "cerf"), ("cerf", "сука"))] {
            var book = AdaptiveRuleBook()
            book.recordConfirmed(original: old.0, converted: old.1)
            book.recordConfirmed(original: old.0, converted: old.1)
            let decision = ManualLearningPolicy.decision(original: new.0, converted: new.1,
                                                         appBundleID: "editor.first", ruleBook: book, model: model)
            XCTAssertEqual(decision, .confirmation(original: new.0, converted: new.1, clearingExceptionFor: "editor.first"))
            decision.apply(to: &book)
            for app in ["editor.first", "editor.second"] {
                XCTAssertTrue(book.isConfirmed(original: new.0, converted: new.1, appBundleID: app))
                XCTAssertFalse(book.isConfirmed(original: old.0, converted: old.1, appBundleID: app))
                XCTAssertEqual(book.bias(original: old.0, converted: old.1, appBundleID: app), 0)
            }
        }
    }

    func testKnownWordReversalWithoutGlobalRuleDoesNotTeachGarbage() {
        XCTAssertEqual(ManualLearningPolicy.decision(original: "страница", converted: "cnhfybwf",
                                                     appBundleID: "editor.first", ruleBook: .init(), model: model), .ignore)
    }

    func testReversalWithoutApplicationIdentityCannotCreateOppositeGlobalRules() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "ешдщьукфй", converted: "tilomeraq")
        XCTAssertTrue(ManualLearningPolicy.shouldPersist(original: "tilomeraq", converted: "ешдщьукфй", model: model))
        for app: String? in [nil, ""] {
            XCTAssertEqual(ManualLearningPolicy.decision(original: "tilomeraq", converted: "ешдщьукфй",
                                                         appBundleID: app, ruleBook: book, model: model), .ignore)
        }
    }

    func testSentenceSelectionsAndSingleLettersAreNotStoredAsUnusableWordRules() {
        for pair in [("b", "и"), ("vs e;t ljvf", "мы уже дома"), ("SEO_", "ЫУЩ_"), ("helloWorld", "руддщЦщкдв")] {
            XCTAssertEqual(ManualLearningPolicy.decision(original: pair.0, converted: pair.1,
                                                         appBundleID: "editor.first", ruleBook: .init(), model: model), .ignore)
        }
        let oversized = String(repeating: "a", count: LearnedCorrectionsArchive.maximumTokenLength + 1)
        XCTAssertEqual(ManualLearningPolicy.decision(original: oversized, converted: KeyMapping.convert(oversized),
                                                     appBundleID: "editor.first", ruleBook: .init(), model: model), .ignore)
    }
}
