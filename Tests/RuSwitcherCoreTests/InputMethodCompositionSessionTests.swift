import XCTest
@testable import RuSwitcherCore

final class InputMethodCompositionSessionTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    func testWrongEnglishKeysCommitRussianWithoutDeletionTransaction() throws {
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        session.append("ghbdtn")

        let result = try XCTUnwrap(session.resolve())

        XCTAssertEqual(result.replacement, "привет")
        XCTAssertTrue(result.wasConverted)
        XCTAssertEqual(result.resolvedLanguage, "ru")
        XCTAssertTrue(session.token.isEmpty)
        XCTAssertEqual(session.currentLanguage, "ru")
    }

    func testPunctuationStaysInsideMarkedTokenUntilCommit() throws {
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        session.append("ghbdtn,")

        let result = try XCTUnwrap(session.resolve())

        XCTAssertEqual(result.replacement, "привет,")
        XCTAssertTrue(result.wasConverted)
    }

    func testCorrectEnglishPhraseUsesContextAndStaysEnglish() throws {
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        var committed: [String] = []
        for word in ["put", "it", "here"] {
            session.beginLanguage("en")
            session.append(word)
            committed.append(try XCTUnwrap(session.resolve()).replacement)
        }

        XCTAssertEqual(committed, ["put", "it", "here"])
        XCTAssertEqual(session.currentLanguage, "en")
    }

    func testRussianModeCanRecoverEnglishWord() throws {
        var session = InputMethodCompositionSession(currentLanguage: "ru", model: model)
        session.append("афиду")

        let result = try XCTUnwrap(session.resolve())

        XCTAssertEqual(result.replacement, "fable")
        XCTAssertTrue(result.wasConverted)
        XCTAssertEqual(result.resolvedLanguage, "en")
    }

    func testBackspaceEditsOnlyCurrentMarkedToken() throws {
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        session.append("ghbdtno")
        XCTAssertTrue(session.deleteBackward())

        let result = try XCTUnwrap(session.resolve())

        XCTAssertEqual(result.original, "ghbdtn")
        XCTAssertEqual(result.replacement, "привет")
    }

    func testConfirmedGlobalRuleIsSharedWithInputMethod() throws {
        var rules = AdaptiveRuleBook()
        rules.recordConfirmed(original: "lrea", converted: "дкуф")
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        session.append("lrea")

        let result = try XCTUnwrap(session.resolve(preferences: InputMethodCompositionPreferences(
            adaptiveRules: rules,
            appBundleID: "example.editor"
        )))

        XCTAssertEqual(result.replacement, "дкуф")
        XCTAssertTrue(result.wasConverted)
        XCTAssertEqual(result.reason, .confirmedByUser)
    }

    func testDisabledAutomaticConversionCommitsLiteral() throws {
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        session.append("ghbdtn")

        let result = try XCTUnwrap(session.resolve(preferences: InputMethodCompositionPreferences(
            automaticConversionEnabled: false
        )))

        XCTAssertEqual(result.replacement, "ghbdtn")
        XCTAssertFalse(result.wasConverted)
    }

    func testForcedToggleCanReverseTheCurrentMarkedTokenRepeatedly() throws {
        var session = InputMethodCompositionSession(currentLanguage: "en", model: model)
        session.append("here")
        let first = try XCTUnwrap(session.forceToggle())
        XCTAssertEqual(first.replacement, "руку")

        session.append(first.replacement)
        let second = try XCTUnwrap(session.forceToggle())
        XCTAssertEqual(second.replacement, "here")
    }
}
