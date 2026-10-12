import XCTest
@testable import RuSwitcherCore

final class PersonalLexiconTests: XCTestCase {
    private let model = LanguageModelStore.bundled!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEligibilityKeepsPlainUnlistedWordsOfTheTypedLanguage() {
        XCTAssertEqual(PersonalLexicon.eligibleWord(typed: "ок", language: "ru", model: model), "ок")
        XCTAssertEqual(PersonalLexicon.eligibleWord(typed: "pstack,", language: "en", model: model), "pstack")
        XCTAssertEqual(PersonalLexicon.eligibleWord(typed: "Кринж", language: "ru", model: model), "кринж")
        // Listed, code-like, mixed, all-caps, too short, or a layout mistake the decoder missed.
        for (typed, language) in [
            ("привет", "ru"), ("here", "en"), ("src/main", "en"), ("ok2", "en"), ("KPI", "en"),
            ("ш", "ru"), ("jr", "en"), ("зыефсл", "ru"), ("ghbdtn", "en"), ("user@x.io", "en"),
        ] {
            XCTAssertNil(PersonalLexicon.eligibleWord(typed: typed, language: language, model: model), typed)
        }
    }

    func testPromotionNeedsSeparateOccasions() {
        var lexicon = PersonalLexicon()
        XCTAssertFalse(lexicon.observe(word: "ок", language: "ru", at: start))
        XCTAssertFalse(lexicon.observe(word: "ок", language: "ru", at: start.addingTimeInterval(5)))
        XCTAssertFalse(lexicon.observe(word: "ок", language: "ru", at: start.addingTimeInterval(60)))
        XCTAssertEqual(lexicon.promotedWords(language: "ru"), [])
        XCTAssertFalse(lexicon.observe(word: "ок", language: "ru", at: start.addingTimeInterval(700)))
        XCTAssertTrue(lexicon.observe(word: "ок", language: "ru", at: start.addingTimeInterval(1_400)))
        XCTAssertEqual(lexicon.promotedWords(language: "ru"), ["ок"])
        XCTAssertEqual(lexicon.promotedWords(language: "en"), [])
        XCTAssertFalse(lexicon.observe(word: "ок", language: "ru", at: start.addingTimeInterval(2_100)))
    }

    func testManualConversionRemovesTheSpelling() {
        var lexicon = PersonalLexicon()
        for step in 0..<3 {
            lexicon.observe(word: "jr", language: "en", at: start.addingTimeInterval(Double(step) * 700))
        }
        XCTAssertEqual(lexicon.promotedWords(language: "en"), ["jr"])
        XCTAssertTrue(lexicon.remove(word: "jr", language: "en"))
        XCTAssertEqual(lexicon.promotedWords(language: "en"), [])
        XCTAssertFalse(lexicon.remove(word: "jr", language: "en"))
    }

    func testCandidateCapEvictsWeakestFirst() {
        var lexicon = PersonalLexicon()
        for index in 0..<PersonalLexicon.candidateLimit {
            lexicon.observe(word: "w\(index)", language: "en", at: start.addingTimeInterval(Double(index)))
        }
        lexicon.observe(word: "w0", language: "en", at: start.addingTimeInterval(100_000))
        lexicon.observe(word: "extra", language: "en", at: start.addingTimeInterval(100_001))
        XCTAssertEqual(lexicon.entries.count, PersonalLexicon.candidateLimit)
        XCTAssertNotNil(lexicon.entries["en\u{1f}w0"])
        XCTAssertNil(lexicon.entries["en\u{1f}w1"])
        XCTAssertNotNil(lexicon.entries["en\u{1f}extra"])
    }

    func testRoundTripsThroughJSON() throws {
        var lexicon = PersonalLexicon()
        lexicon.observe(word: "кринж", language: "ru", at: start)
        let data = try JSONEncoder().encode(lexicon)
        XCTAssertEqual(try JSONDecoder().decode(PersonalLexicon.self, from: data), lexicon)
    }
}
