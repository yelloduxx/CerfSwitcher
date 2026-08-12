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
}
