import Foundation
import XCTest
@testable import RuSwitcherCore

final class PersonalDataArchiveTests: XCTestCase {
    private func fixture() throws -> PersonalDataArchive {
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)
        let source = KeyMapping.convert("hello")
        let book = AdaptiveRuleBook(rules: [
            AdaptiveRule(original: source, converted: "hello", positiveCount: 9, negativeCount: 2,
                         confirmed: true, lastUsed: date),
            AdaptiveRule(original: source, converted: "hello", appBundleID: "chat.one", negativeCount: 3,
                         applicationException: true, lastUsed: date),
            AdaptiveRule(original: KeyMapping.convert("world"), converted: "world", positiveCount: 2,
                         negativeCount: 4, lastUsed: date),
        ])
        var personal = PersonalLexicon()
        personal.observe(word: "qzvrtk", language: "en", at: date)
        personal.observe(word: "another", language: "en", at: date)
        personal.observe(word: "another", language: "en", at: date.addingTimeInterval(700))
        personal.observe(word: "another", language: "en", at: date.addingTimeInterval(1400))
        return try PersonalDataArchive(payload: .init(
            adaptiveRules: book, personalLexicon: personal, userDictionary: ["Figma", "Nuxt"],
            alwaysConvertWords: ["qzvrtk"], deniedWords: ["GitHub", "x.com"],
            deniedAppsAdded: ["chat.one"], deniedAppsRemoved: ["com.apple.Terminal"]
        ), exportedAt: date)
    }

    private func modifying(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture().encoded()) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testAllDataRoundTripPreservesCountersCandidatesPromotionsAndRawOverrides() throws {
        let original = try fixture()
        let decoded = try PersonalDataArchive.decode(original.encoded())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.payload.adaptiveRules.rules.count, 3)
        XCTAssertEqual(decoded.payload.personalLexicon.entries.count, 2)
        XCTAssertEqual(decoded.payload.personalLexicon.promotedWords(language: "en"), ["another"])
        XCTAssertEqual(decoded.payload.deniedAppsRemoved, ["com.apple.Terminal"])
        XCTAssertEqual(try decoded.encoded(), try original.encoded())
    }

    func testMalformedFinalSectionNeverProducesValidatedPayload() throws {
        let data = try modifying { $0["deniedAppsRemoved"] = ["\u{0}"] }
        XCTAssertThrowsError(try PersonalDataArchive.decode(data)) {
            XCTAssertEqual($0 as? PersonalDataArchiveError, .invalidSection("deniedAppsRemoved"))
        }
        let wrongType = try modifying { $0["deniedAppsRemoved"] = "not-an-array" }
        XCTAssertThrowsError(try PersonalDataArchive.decode(wrongType))
    }

    func testEverySectionIsRequiredAndInvalidEntriesAreNotSilentlyDropped() throws {
        for section in ["adaptiveRules", "personalLexicon", "userDictionary", "alwaysConvertWords",
                        "deniedWords", "deniedAppsAdded", "deniedAppsRemoved"] {
            XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0.removeValue(forKey: section) }), section)
        }
        for invalid in [["Figma", "figma"], ["valid", "42"], ["word,"], [""]] {
            XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0["userDictionary"] = invalid }))
        }
        for section in ["alwaysConvertWords", "deniedWords", "deniedAppsAdded", "deniedAppsRemoved"] {
            for invalid in [[""], ["\n"], [String(repeating: "x", count: 257)]] {
                XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0[section] = invalid }), section)
            }
        }
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0["deniedAppsRemoved"] = ["chat.one"] }))
    }

    func testRawRulesAreValidatedBeforeBookMigration() throws {
        for (field, value) in [("original", "a" as Any), ("converted", "" as Any),
                               ("positiveCount", -1 as Any), ("negativeCount", 1_000_001 as Any),
                               ("original", "UPPER" as Any), ("lastUsed", "invalid" as Any)] {
            let data = try modifying {
                var book = $0["adaptiveRules"] as! [String: Any]
                var rules = book["rules"] as! [[String: Any]]
                rules[0][field] = value
                book["rules"] = rules
                $0["adaptiveRules"] = book
            }
            XCTAssertThrowsError(try PersonalDataArchive.decode(data), field)
        }
        for version in [3, 99] {
            XCTAssertThrowsError(try PersonalDataArchive.decode(modifying {
                var book = $0["adaptiveRules"] as! [String: Any]
                book["modelVersion"] = version
                $0["adaptiveRules"] = book
            }))
        }
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying {
            var book = $0["adaptiveRules"] as! [String: Any]
            var rules = book["rules"] as! [[String: Any]]
            rules[0].removeValue(forKey: "positiveCount")
            book["rules"] = rules
            $0["adaptiveRules"] = book
        }))
    }

    func testPersonalLexiconValidationRejectsBadKeysCountsAndPromotion() throws {
        let valid = try fixture().payload.personalLexicon
        for key in ["fr\u{1f}word", "en\u{1f}Word", "en\u{1f}", "en\u{1f}bad\u{1f}key"] {
            var invalid = valid
            invalid.entries[key] = valid.entries.values.first
            XCTAssertThrowsError(try PersonalDataArchive.validatePersonalLexicon(invalid))
        }
        var invalid = valid
        invalid.entries["en\u{1f}qzvrtk"]?.count = -1
        XCTAssertThrowsError(try PersonalDataArchive.validatePersonalLexicon(invalid))
        invalid = valid
        invalid.entries["en\u{1f}qzvrtk"]?.promoted = true
        XCTAssertThrowsError(try PersonalDataArchive.validatePersonalLexicon(invalid))
        invalid = valid
        invalid.version = 2
        XCTAssertThrowsError(try PersonalDataArchive.validatePersonalLexicon(invalid))
    }

    func testSectionAndFileBoundsAndVersions() throws {
        XCTAssertThrowsError(try PersonalDataArchive.decode(Data(repeating: 32, count: PersonalDataArchive.maximumFileSize + 1))) {
            XCTAssertEqual($0 as? PersonalDataArchiveError, .fileTooLarge)
        }
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0["formatVersion"] = 99 })) {
            XCTAssertEqual($0 as? PersonalDataArchiveError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0["format"] = "foreign" }))
        for (section, limit) in [("userDictionary", UserDictionary.maximumWordCount),
                                 ("deniedWords", PersonalDataArchive.maximumExceptionCount),
                                 ("alwaysConvertWords", PersonalDataArchive.maximumExceptionCount),
                                 ("deniedAppsAdded", PersonalDataArchive.maximumAppCount),
                                 ("deniedAppsRemoved", PersonalDataArchive.maximumAppCount)] {
            XCTAssertThrowsError(try PersonalDataArchive.decode(modifying {
                $0[section] = Array(repeating: "word", count: limit + 1)
            }), section)
        }
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying {
            var book = $0["adaptiveRules"] as! [String: Any]
            let rules = book["rules"] as! [[String: Any]]
            book["rules"] = Array(repeating: rules[0], count: 2_001)
            $0["adaptiveRules"] = book
        }))
    }

    func testOldLearnedArchiveRemainsSeparateAndUnchanged() throws {
        let full = try fixture()
        let old = LearnedCorrectionsArchive(ruleBook: full.payload.adaptiveRules,
                                           exportedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try old.encoded()
        let decoded = try LearnedCorrectionsArchive.decode(data)
        XCTAssertEqual(decoded.format, "RuSwitcherLearnedCorrections")
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(try decoded.encoded(), data)
        XCTAssertThrowsError(try PersonalDataArchive.decode(data))
        XCTAssertThrowsError(try LearnedCorrectionsArchive.decode(full.encoded()))
    }

    func testPersonalCandidateAndPromotedLimitsAreIndependent() throws {
        for (count, promoted) in [(PersonalLexicon.candidateLimit + 1, false), (PersonalLexicon.promotedLimit + 1, true)] {
            var personal = PersonalLexicon()
            for index in 0..<count {
                let suffix = [index / (26 * 26), (index / 26) % 26, index % 26]
                    .map { String(UnicodeScalar(97 + $0)!) }.joined()
                personal.entries["en\u{1f}word" + suffix] = PersonalLexicon.Entry(
                    count: promoted ? 3 : 1, lastSeen: Date(), promoted: promoted
                )
            }
            XCTAssertThrowsError(try PersonalDataArchive.validatePersonalLexicon(personal))
        }
    }

    func testInvalidDatesAndAppIdentityAreRejected() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try PersonalDataArchive(payload: fixture.payload,
                                                     exportedAt: Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying { $0["deniedAppsAdded"] = ["chat one"] }))
        XCTAssertThrowsError(try PersonalDataArchive.decode(modifying {
            var book = $0["adaptiveRules"] as! [String: Any]
            var rules = book["rules"] as! [[String: Any]]
            rules[0]["applicationException"] = true
            book["rules"] = rules
            $0["adaptiveRules"] = book
        }))
    }
}
