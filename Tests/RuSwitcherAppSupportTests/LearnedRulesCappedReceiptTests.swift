import Foundation
import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

@MainActor
final class LearnedRulesCappedReceiptTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!
    private let wrong = KeyMapping.convert("hello")
    private let maximumCount = 1_000_000

    override func setUp() async throws {
        domain = "com.ruswitcher.tests.capped-receipts.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    func testCappedManualSaveExportsRestoresAndUndoes() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let initial = AdaptiveRuleBook(rules: [
            AdaptiveRule(original: wrong, converted: "hello", positiveCount: maximumCount,
                         negativeCount: maximumCount, lastUsed: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        _ = try store.importRules(LearnedCorrectionsArchive(ruleBook: initial).encoded())
        let before = store.snapshot
        let saved = try save(store)
        let after = LearnedRulesStore(defaults: defaults).snapshot
        XCTAssertEqual(after.rules.first?.positiveCount, maximumCount)
        XCTAssertEqual(after.rules.first?.negativeCount, maximumCount)
        XCTAssertTrue(after.isConfirmed(original: wrong, converted: "hello", appBundleID: nil))
        XCTAssertEqual(try LearnedCorrectionsArchive.decode(store.exportRules()).rules.first?.positiveCount, maximumCount)
        let archive = try PersonalDataArchive(payload: .init(
            adaptiveRules: after, personalLexicon: PersonalLexicon(), userDictionary: [],
            alwaysConvertWords: [], deniedWords: [], deniedAppsAdded: [], deniedAppsRemoved: []
        ))
        let decoded = try PersonalDataArchive.decode(archive.encoded())
        XCTAssertEqual(decoded.payload.adaptiveRules, after)
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot, before)
        try store.replace(with: decoded.payload.adaptiveRules)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot, after)
        let next = try save(store)
        XCTAssertEqual(try store.undo(next.receipt), .undone)
        XCTAssertEqual(store.snapshot, after)
    }

    func testOrdinaryContinuationKeepsManualUndoAndUnrelatedPair() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let saved = try save(store)
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        store.recordPositive(original: wrong, converted: "hello")
        store.recordPositive(original: wrong + ",", converted: "hello,")
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        XCTAssertNil(store.validateUndo(saved.receipt))
        let writer = LearnedRulesStore(defaults: defaults)
        writer.recordPositive(original: KeyMapping.convert("world"), converted: "world")
        writer.recordPositive(original: KeyMapping.convert("world"), converted: "world")
        let unrelated = try XCTUnwrap(writer.snapshot.rules.first { $0.converted == "world" })
        XCTAssertEqual(unrelated.positiveCount, 2)
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot.rules, [unrelated])
    }

    func testInvalidManualResultDoesNotWriteOrInvalidateExistingReceipt() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let saved = try XCTUnwrap(store.saveManualCorrection(
            original: KeyMapping.convert("qzvrtk"), converted: "qzvrtk", appBundleID: nil,
            model: XCTUnwrap(LanguageModelStore.bundled)
        ))
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        XCTAssertThrowsError(try store.saveManualCorrection(
            original: "qzvrtk", converted: KeyMapping.convert("qzvrtk"), appBundleID: "bad app",
            model: LanguageModelStore.bundled
        )) {
            XCTAssertEqual($0 as? PersonalDataArchiveError, .invalidSection("adaptiveRules"))
        }
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        XCTAssertNil(store.validateUndo(saved.receipt))
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
    }

    func testApplicationExceptionSaveKeepsDirectionAndUndoPreservesUnrelatedPair() throws {
        let store = LearnedRulesStore(defaults: defaults)
        var initial = AdaptiveRuleBook()
        initial.recordConfirmed(original: "hello", converted: wrong)
        store.snapshot = initial
        let saved = try XCTUnwrap(store.saveApplicationException(
            original: "hello", converted: wrong, appBundleID: "chat.one"
        ))
        XCTAssertEqual(saved.decision, .applicationException(original: "hello", converted: wrong, appBundleID: "chat.one"))
        let fresh = LearnedRulesStore(defaults: defaults)
        XCTAssertEqual(fresh.snapshot.rules.first, initial.rules.first)
        XCTAssertTrue(fresh.snapshot.hasApplicationException(original: "hello", converted: wrong, appBundleID: "chat.one"))
        XCTAssertFalse(fresh.snapshot.isConfirmed(original: wrong, converted: "hello", appBundleID: nil))
        fresh.recordPositive(original: KeyMapping.convert("world"), converted: "world")
        let unrelated = try XCTUnwrap(fresh.snapshot.rules.first { $0.converted == "world" })
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot.rules, initial.rules + [unrelated])
        XCTAssertEqual(try store.undo(saved.receipt), .invalidReceipt)
    }

    func testApplicationExceptionRequiresGlobalConfirmationAndNonemptyApp() throws {
        let store = LearnedRulesStore(defaults: defaults)
        for book in [AdaptiveRuleBook(), AdaptiveRuleBook(rules: [
            AdaptiveRule(original: wrong, converted: "hello", positiveCount: 5),
        ]), AdaptiveRuleBook(rules: [
            AdaptiveRule(original: wrong, converted: "hello", appBundleID: "chat.one", confirmed: true),
        ])] {
            store.snapshot = book
            let before = defaults.data(forKey: LearnedRulesStore.storageKey)
            XCTAssertNil(try store.saveApplicationException(original: wrong, converted: "hello", appBundleID: "chat.one"))
            XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        }
        let saved = try save(store)
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        for app: String? in [nil, ""] {
            XCTAssertNil(try store.saveApplicationException(original: wrong, converted: "hello", appBundleID: app))
        }
        XCTAssertThrowsError(try store.saveApplicationException(original: wrong, converted: "hello", appBundleID: "bad app"))
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        XCTAssertNil(store.validateUndo(saved.receipt))
    }

    func testCappedApplicationExceptionCanBeSavedAndUndone() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let initial = AdaptiveRuleBook(rules: [
            AdaptiveRule(original: wrong, converted: "hello", positiveCount: maximumCount, confirmed: true),
            AdaptiveRule(original: wrong, converted: "hello", appBundleID: "chat.one", negativeCount: maximumCount,
                         applicationException: true, lastUsed: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        try store.replace(with: initial)
        let saved = try XCTUnwrap(store.saveApplicationException(original: wrong, converted: "hello", appBundleID: "chat.one"))
        XCTAssertEqual(store.snapshot.rules[1].negativeCount, maximumCount)
        XCTAssertNoThrow(try PersonalDataArchive.validateAdaptiveRules(store.snapshot))
        XCTAssertNoThrow(try store.exportRules())
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot, initial)
    }

    private func save(_ store: LearnedRulesStore) throws -> ManualLearningSave {
        try XCTUnwrap(store.saveManualCorrection(original: wrong, converted: "hello", appBundleID: nil,
                                                 model: XCTUnwrap(LanguageModelStore.bundled)))
    }
}
