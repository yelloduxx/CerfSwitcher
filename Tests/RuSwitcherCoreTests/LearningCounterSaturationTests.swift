import Foundation
import XCTest
@testable import RuSwitcherCore

final class LearningCounterSaturationTests: XCTestCase {
    private let maximumCount = 1_000_000
    private let original = KeyMapping.convert("hello")
    private let app = "chat.one"

    func testPositiveFeedbackSaturatesAndPreservesOrdinaryIncrements() throws {
        for initial in [0, 7, maximumCount - 1, maximumCount] {
            var book = AdaptiveRuleBook(rules: [
                AdaptiveRule(original: original, converted: "hello", positiveCount: initial),
            ])
            for step in 1...3 {
                book.recordPositive(original: original, converted: "hello")
                XCTAssertEqual(book.rules.first?.positiveCount, min(initial + step, maximumCount))
                XCTAssertEqual(book.rules.first?.negativeCount, 0)
                XCTAssertFalse(try XCTUnwrap(book.rules.first).confirmed)
            }
            try assertRoundTrip(book)
        }
    }

    func testNegativeFeedbackSaturatesAndClearsConfirmation() throws {
        for scope in [nil, app] {
            for initial in [0, 7, maximumCount - 1, maximumCount] {
                var book = AdaptiveRuleBook(rules: [
                    AdaptiveRule(original: original, converted: "hello", appBundleID: scope,
                                 positiveCount: 4, negativeCount: initial, confirmed: true),
                ])
                for step in 1...3 {
                    book.recordNegative(original: original, converted: "hello", appBundleID: scope)
                    XCTAssertEqual(book.rules.first?.negativeCount, min(initial + step, maximumCount))
                    XCTAssertEqual(book.rules.first?.positiveCount, 4)
                    XCTAssertFalse(try XCTUnwrap(book.rules.first).confirmed)
                }
                try assertRoundTrip(book)
            }
        }
    }

    func testManualConfirmationSaturatesAndStillConfirms() throws {
        for initial in [0, 7, maximumCount - 1, maximumCount] {
            var book = AdaptiveRuleBook(rules: [
                AdaptiveRule(original: original, converted: "hello", positiveCount: initial, negativeCount: 2),
            ])
            for step in 1...3 {
                book.recordConfirmed(original: original, converted: "hello")
                XCTAssertEqual(book.rules.first?.positiveCount, min(initial + step, maximumCount))
                XCTAssertEqual(book.rules.first?.negativeCount, 2)
                XCTAssertTrue(book.isConfirmed(original: original, converted: "hello", appBundleID: nil))
            }
            try assertRoundTrip(book)
        }
    }

    func testApplicationExceptionSaturatesForNegativeAndManualReversal() throws {
        for initial in [0, 7, maximumCount - 1, maximumCount] {
            var book = AdaptiveRuleBook(rules: [
                AdaptiveRule(original: original, converted: "hello", positiveCount: 5, confirmed: true),
                AdaptiveRule(original: original, converted: "hello", appBundleID: app,
                             negativeCount: initial, applicationException: true),
            ])
            let global = book.rules[0]
            book.recordNegative(original: original, converted: "hello", appBundleID: app)
            XCTAssertEqual(book.rules[1].negativeCount, min(initial + 1, maximumCount))
            book.recordManualCorrection(original: "hello", converted: original, appBundleID: app)
            XCTAssertEqual(book.rules[1].negativeCount, min(initial + 2, maximumCount))
            XCTAssertEqual(book.rules[0], global)
            XCTAssertTrue(book.hasApplicationException(original: original, converted: "hello", appBundleID: app))
            try assertRoundTrip(book)
        }
    }

    func testPersonalSightingsSaturateAndKeepPromotionAndOccasionTiming() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000.125)
        let key = "en\u{1f}qzvrtk"
        for initial in [1, 2, 7, maximumCount - 1, maximumCount] {
            var lexicon = PersonalLexicon(entries: [
                key: .init(count: initial, lastSeen: start, promoted: initial >= PersonalLexicon.promotionCount),
            ])
            XCTAssertFalse(lexicon.observe(word: "qzvrtk", language: "en", at: start.addingTimeInterval(1)))
            XCTAssertEqual(lexicon.entries[key]?.count, initial)
            XCTAssertEqual(lexicon.entries[key]?.lastSeen, start)
            for step in 1...3 {
                let date = start.addingTimeInterval(Double(step) * PersonalLexicon.occasionInterval)
                let promoted = lexicon.observe(word: "qzvrtk", language: "en", at: date)
                XCTAssertEqual(promoted, initial + step == PersonalLexicon.promotionCount)
                XCTAssertEqual(lexicon.entries[key]?.count, min(initial + step, maximumCount))
                XCTAssertEqual(lexicon.entries[key]?.lastSeen, date)
                XCTAssertEqual(lexicon.entries[key]?.promoted, initial + step >= PersonalLexicon.promotionCount)
            }
            try assertRoundTrip(AdaptiveRuleBook(), lexicon: lexicon)
        }
    }

    private func assertRoundTrip(_ book: AdaptiveRuleBook, lexicon: PersonalLexicon = .init(),
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let archive = try PersonalDataArchive(payload: .init(
            adaptiveRules: book, personalLexicon: lexicon, userDictionary: [],
            alwaysConvertWords: [], deniedWords: [], deniedAppsAdded: [], deniedAppsRemoved: []
        ))
        XCTAssertEqual(try PersonalDataArchive.decode(archive.encoded()), archive, file: file, line: line)
        let legacy = LearnedCorrectionsArchive(ruleBook: book)
        let decoded = try LearnedCorrectionsArchive.decode(legacy.encoded())
        XCTAssertEqual(decoded.formatVersion, 1, file: file, line: line)
        XCTAssertEqual(decoded.rules.map(\.positiveCount), book.rules.map(\.positiveCount), file: file, line: line)
        XCTAssertEqual(decoded.rules.map(\.negativeCount), book.rules.map(\.negativeCount), file: file, line: line)
        XCTAssertEqual(decoded.rules.map(\.confirmed), book.rules.map(\.confirmed), file: file, line: line)
        XCTAssertEqual(decoded.rules.map(\.applicationException), book.rules.map(\.applicationException), file: file, line: line)
    }
}
