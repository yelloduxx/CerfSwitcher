import XCTest
@testable import RuSwitcherCore

/// The Exceptions page outranks everything learned or listed:
/// never-convert > always-convert > learned pairs and app exceptions >
/// user dictionary and personal words > decoder statistics.
final class ExceptionPrecedenceTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    private func output(
        _ typed: String,
        current: String = "en",
        target: String = "ru",
        context: [String] = [],
        never: Set<String> = [],
        always: Set<String> = [],
        learned: AdaptiveRuleBook = AdaptiveRuleBook(),
        app: String = "chat.one",
        switchedLayoutByHand: Bool = false,
        store: LanguageModelStore? = nil
    ) -> String {
        var belief = LanguageBelief.neutral
        for word in context {
            belief.observe(language: SmartTokenizer.languageHint(for: word) ?? current)
        }
        let decision = LayoutDecoder.evaluate(
            typed: typed, converted: KeyMapping.convert(typed), currentLanguage: current, targetLanguage: target,
            capsLock: false, contextWords: context, languageBelief: belief,
            switchedLayoutByHand: switchedLayoutByHand,
            policy: AutoConvertPolicy(neverConvert: never, alwaysConvert: always),
            adaptiveBias: { learned.bias(original: $0, converted: $1, appBundleID: app) },
            isConfirmed: { learned.isConfirmed(original: $0, converted: $1, appBundleID: app) },
            model: store ?? model
        ).decision
        return decision.verdict == .switchToConverted ? decision.candidate.replacement : typed
    }

    private func book(confirming original: String, _ converted: String, exceptionIn app: String? = nil) -> AdaptiveRuleBook {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: original, converted: converted)
        if let app { book.recordNegative(original: original, converted: converted, appBundleID: app) }
        return book
    }

    func testNeverConvertBeatsAConfirmedLearnedPair() {
        let confirmed = book(confirming: "ghbdtn", "привет")
        XCTAssertEqual(output("ghbdtn", learned: confirmed), "привет")
        XCTAssertEqual(output("ghbdtn", never: ["ghbdtn"], learned: confirmed), "ghbdtn")
        XCTAssertEqual(output("ghbdtn", never: ["привет"], learned: confirmed), "ghbdtn")
        XCTAssertEqual(output("ghbdtn", never: ["ghbdtn"], always: ["привет"], learned: confirmed), "ghbdtn")
    }

    func testNeverConvertMatchesTheTypedWordWithoutItsPunctuation() {
        let confirmed = book(confirming: "ghbdtn", "привет")
        XCTAssertEqual(output("ghbdtn,", learned: confirmed), "привет,")
        XCTAssertEqual(output("ghbdtn,", never: ["ghbdtn"], learned: confirmed), "ghbdtn,")
        XCTAssertEqual(output("(ghbdtn)", never: ["ghbdtn"], learned: confirmed), "(ghbdtn)")
        XCTAssertEqual(output("ghbdtn,", never: ["привет"], learned: confirmed), "ghbdtn,")
    }

    func testNeverConvertBeatsUserDictionaryAndPersonalWords() {
        let listed = model.personalized(with: UserDictionary(words: ["кринж"]).wordsByLanguage)
        XCTAssertEqual(output("rhby;", context: ["это", "текст"], store: listed), "кринж")
        XCTAssertEqual(output("rhby;", context: ["это", "текст"], never: ["кринж"], store: listed), "rhby;")
        XCTAssertEqual(output("rhby;", context: ["это", "текст"], never: ["rhby"], store: listed), "rhby;")

        let personal = model.personalized(with: ["ru": ["ок"], "en": []])
        XCTAssertEqual(output("jr", store: personal), "ок")
        XCTAssertEqual(output("jr", never: ["ок"], store: personal), "jr")
        XCTAssertEqual(output("jr", never: ["jr"], store: personal), "jr")
    }

    func testAlwaysConvertBeatsAppExceptionNegativeBiasAndHandSwitch() {
        let exception = book(confirming: "ghbdtn", "привет", exceptionIn: "chat.one")
        XCTAssertEqual(output("ghbdtn", learned: exception, app: "chat.two"), "привет")
        XCTAssertEqual(output("ghbdtn", learned: exception), "ghbdtn")
        XCTAssertEqual(output("ghbdtn", always: ["привет"], learned: exception), "привет")

        var rejected = AdaptiveRuleBook()
        for _ in 0..<5 { rejected.recordNegative(original: "ghbdtn", converted: "привет", appBundleID: "chat.one") }
        XCTAssertEqual(rejected.bias(original: "ghbdtn", converted: "привет", appBundleID: "chat.one"), -12.5)
        XCTAssertEqual(output("ghbdtn", learned: rejected), "ghbdtn")
        XCTAssertEqual(output("ghbdtn", always: ["привет"], learned: rejected), "привет")

        let handSwitched = ["наши", "родители"]
        let handException = book(confirming: "vs", "мы", exceptionIn: "chat.one")
        XCTAssertEqual(output("vs", context: handSwitched), "мы")
        XCTAssertEqual(output("vs", context: handSwitched, switchedLayoutByHand: true), "vs")
        XCTAssertEqual(output("vs", context: handSwitched, always: ["мы"], switchedLayoutByHand: true), "мы")
        XCTAssertEqual(output("vs", context: handSwitched, always: ["мы"], learned: handException,
                              switchedLayoutByHand: true), "мы")
    }
}
