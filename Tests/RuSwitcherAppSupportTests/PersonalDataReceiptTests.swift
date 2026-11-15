import Foundation
import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

@MainActor
final class PersonalDataReceiptTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!
    private let wrong = KeyMapping.convert("hello")

    override func setUp() async throws {
        domain = "com.ruswitcher.tests.receipts.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    private func save(_ store: LearnedRulesStore) throws -> ManualLearningSave {
        try XCTUnwrap(store.saveManualCorrection(original: wrong, converted: "hello", appBundleID: "chat.one",
                                                 model: XCTUnwrap(LanguageModelStore.bundled)))
    }

    func testUndoPreservesUnrelatedLaterWritesAndFreshStoreReads() throws {
        let store = LearnedRulesStore(defaults: defaults)
        defaults.set("untouched", forKey: "other-setting")
        let saved = try save(store)
        XCTAssertEqual(saved.decision, .confirmation(original: wrong, converted: "hello", clearingExceptionFor: "chat.one"))
        XCTAssertTrue(LearnedRulesStore(defaults: defaults).snapshot.isConfirmed(original: wrong, converted: "hello", appBundleID: nil))
        let other = LearnedRulesStore(defaults: defaults)
        other.recordPositive(original: KeyMapping.convert("world"), converted: "world")
        let unrelated = try XCTUnwrap(other.snapshot.rules.first { $0.converted == "world" })
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot.rules, [unrelated])
        XCTAssertEqual(defaults.string(forKey: "other-setting"), "untouched")
        XCTAssertEqual(try store.undo(saved.receipt), .invalidReceipt)
    }

    func testForeignReceiptAndSameKeyConflictLeaveBytesUnchanged() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let saved = try save(store)
        let other = LearnedRulesStore(defaults: defaults)
        XCTAssertEqual(try other.undo(saved.receipt), .invalidReceipt)
        _ = try XCTUnwrap(other.saveManualCorrection(original: wrong + ",", converted: "hello,",
                                                     appBundleID: nil, model: LanguageModelStore.bundled))
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        XCTAssertEqual(store.validateUndo(saved.receipt), .conflict)
        XCTAssertEqual(try store.undo(saved.receipt), .conflict)
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
    }

    func testUndoRestoresReverseConfirmationClearedExceptionAndPrunedEntry() throws {
        let store = LearnedRulesStore(defaults: defaults)
        var before = AdaptiveRuleBook()
        before.recordConfirmed(original: "hello", converted: wrong)
        before.recordConfirmed(original: wrong, converted: "hello")
        before.recordNegative(original: wrong, converted: "hello", appBundleID: "chat.one")
        // The opposite confirmation can exist after an old archive import.
        var rules = before.rules
        let reverse = try XCTUnwrap(rules.firstIndex { $0.original == "hello" })
        rules[reverse].confirmed = true
        rules[reverse].positiveCount = 7
        rules.append(AdaptiveRule(original: KeyMapping.convert("world"), converted: "world", positiveCount: 1,
                                  lastUsed: Date(timeIntervalSince1970: 1)))
        before = AdaptiveRuleBook(rules: rules)
        store.snapshot = before
        let saved = try save(store)
        XCTAssertFalse(store.snapshot.hasApplicationException(original: wrong, converted: "hello", appBundleID: "chat.one"))
        XCTAssertFalse(store.snapshot.isConfirmed(original: "hello", converted: wrong, appBundleID: nil))
        XCTAssertFalse(store.snapshot.rules.contains { $0.converted == "world" })
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot, before)
    }

    func testApplicationExceptionSaveCanBeUndone() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let word = "qzvrtk", source = KeyMapping.convert(word)
        var before = AdaptiveRuleBook()
        before.recordConfirmed(original: source, converted: word)
        store.snapshot = before
        let saved = try XCTUnwrap(store.saveManualCorrection(original: word, converted: source,
                                                             appBundleID: "chat.one", model: model))
        XCTAssertEqual(saved.decision, .applicationException(original: source, converted: word, appBundleID: "chat.one"))
        XCTAssertEqual(try store.undo(saved.receipt), .undone)
        XCTAssertEqual(store.snapshot, before)
    }

    func testIgnoreAndFailedReadBackDoNotAcknowledgeSave() throws {
        let rejecting = try XCTUnwrap(RejectingDefaults(suiteName: domain))
        let store = LearnedRulesStore(defaults: rejecting)
        XCTAssertNil(try store.saveManualCorrection(original: "someCode", converted: KeyMapping.convert("someCode"),
                                                    appBundleID: nil, model: LanguageModelStore.bundled))
        XCTAssertNil(defaults.data(forKey: LearnedRulesStore.storageKey))
        rejecting.rejectWrites = true
        XCTAssertThrowsError(try store.saveManualCorrection(original: wrong, converted: "hello", appBundleID: "chat.one",
                                                             model: LanguageModelStore.bundled)) {
            XCTAssertEqual($0 as? PersonalDataStoreError, .readBackFailed)
        }
        XCTAssertEqual(store.recordManualCorrection(original: wrong, converted: "hello", appBundleID: nil,
                                                    model: LanguageModelStore.bundled), .ignore)
        XCTAssertTrue(store.snapshot.rules.isEmpty)
    }

    func testReceiptWindowIsBoundedAndReplacementInvalidatesOldReceipt() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let first = try save(store)
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        for index in 0..<32 {
            let suffix = String(UnicodeScalar(97 + index / 26)!) + String(UnicodeScalar(97 + index % 26)!)
            let word = "qzvrtk" + suffix
            _ = try XCTUnwrap(store.saveManualCorrection(original: KeyMapping.convert(word), converted: word,
                                                         appBundleID: nil, model: model))
        }
        XCTAssertEqual(try store.undo(first.receipt), .invalidReceipt)
        let recent = try save(store)
        store.snapshot = store.snapshot
        XCTAssertEqual(try store.undo(recent.receipt), .invalidReceipt)
    }

    func testObservedSameKeyABAStillConflicts() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let saved = try save(store)
        let after = store.snapshot
        let writer = LearnedRulesStore(defaults: defaults)
        _ = try save(writer)
        _ = store.snapshot
        writer.snapshot = after
        XCTAssertEqual(try store.undo(saved.receipt), .conflict)
        XCTAssertEqual(store.snapshot, after)
    }

    func testLexiconRemovalRestoresOnlyItsEntryAndPersistsPendingSightings() throws {
        let store = PersonalLexiconStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in [0.0, 700, 1400] { store.observe(word: "qzvrtk", language: "en", at: start.addingTimeInterval(offset)) }
        let before = store.snapshot
        let receipt = try XCTUnwrap(store.removeWithReceipt(word: "QZVRTK", language: "en"))
        XCTAssertTrue(receipt.wasPromoted)
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).entryCount, 0)
        store.observe(word: "another", language: "en", at: start)
        XCTAssertEqual(try store.undo(receipt), .undone)
        let reloaded = PersonalLexiconStore(defaults: defaults).snapshot
        XCTAssertEqual(reloaded.entries["en\u{1f}qzvrtk"], before.entries["en\u{1f}qzvrtk"])
        XCTAssertNotNil(reloaded.entries["en\u{1f}another"])
        XCTAssertEqual(try store.undo(receipt), .invalidReceipt)
    }

    func testLexiconConflictForeignReceiptAndReplacementValidation() throws {
        let store = PersonalLexiconStore(defaults: defaults)
        store.observe(word: "qzvrtk", language: "en")
        let receipt = try XCTUnwrap(store.removeWithReceipt(word: "qzvrtk", language: "en"))
        XCTAssertEqual(try PersonalLexiconStore(defaults: defaults).undo(receipt), .invalidReceipt)
        store.observe(word: "qzvrtk", language: "en")
        store.remove(word: "qzvrtk", language: "en")
        XCTAssertEqual(try store.undo(receipt), .conflict)
        let before = defaults.data(forKey: PersonalLexiconStore.storageKey)
        XCTAssertThrowsError(try store.replace(with: PersonalLexicon(version: 99)))
        XCTAssertEqual(defaults.data(forKey: PersonalLexiconStore.storageKey), before)
        try store.replace(with: PersonalLexicon())
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).snapshot, PersonalLexicon())
        XCTAssertEqual(try store.undo(receipt), .invalidReceipt)
    }

    func testDictionaryReplacementIsStrictAndFreshReadsMatch() throws {
        let store = UserDictionaryStore(defaults: defaults)
        try store.replace(with: ["Figma", "Nuxt"])
        XCTAssertEqual(UserDictionaryStore(defaults: defaults).snapshot, ["Figma", "Nuxt"])
        let before = defaults.stringArray(forKey: UserDictionaryStore.storageKey)
        for invalid in [["word", "WORD"], ["word,"], ["42"], [""]] {
            XCTAssertThrowsError(try store.replace(with: invalid))
            XCTAssertEqual(defaults.stringArray(forKey: UserDictionaryStore.storageKey), before)
        }
        try store.replace(with: [])
        XCTAssertEqual(UserDictionaryStore(defaults: defaults).snapshot, [])
    }

    func testValidatedRuleReplacementInvalidatesReceiptAndReadsBack() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let saved = try save(store)
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        XCTAssertThrowsError(try store.replace(with: AdaptiveRuleBook(modelVersion: 99)))
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        try store.replace(with: AdaptiveRuleBook())
        XCTAssertTrue(LearnedRulesStore(defaults: defaults).snapshot.rules.isEmpty)
        XCTAssertEqual(try store.undo(saved.receipt), .invalidReceipt)
    }

    func testFailedReplacementDoesNotPublishNewInMemorySnapshot() throws {
        let rejecting = try XCTUnwrap(RejectingDefaults(suiteName: domain))
        let dictionary = UserDictionaryStore(defaults: rejecting)
        let personal = PersonalLexiconStore(defaults: rejecting)
        let learned = LearnedRulesStore(defaults: rejecting)
        rejecting.rejectWrites = true
        XCTAssertThrowsError(try dictionary.replace(with: ["Figma"]))
        XCTAssertEqual(dictionary.snapshot, [])
        var lexicon = PersonalLexicon()
        lexicon.observe(word: "qzvrtk", language: "en")
        XCTAssertThrowsError(try personal.replace(with: lexicon))
        XCTAssertEqual(personal.snapshot, PersonalLexicon())
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: wrong, converted: "hello")
        XCTAssertThrowsError(try learned.replace(with: book))
        XCTAssertTrue(learned.snapshot.rules.isEmpty)
    }

    func testLexiconExternalUnrelatedWriteSurvivesUndoButDirtyConflictDoesNotOverwrite() throws {
        let store = PersonalLexiconStore(defaults: defaults)
        store.observe(word: "qzvrtk", language: "en")
        let receipt = try XCTUnwrap(store.removeWithReceipt(word: "qzvrtk", language: "en"))
        let other = PersonalLexiconStore(defaults: defaults)
        other.observe(word: "another", language: "en")
        other.flush()
        XCTAssertEqual(try store.undo(receipt), .undone)
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).entryCount, 2)

        let second = try XCTUnwrap(store.removeWithReceipt(word: "qzvrtk", language: "en"))
        store.observe(word: "local", language: "en")
        let external = PersonalLexiconStore(defaults: defaults)
        external.observe(word: "external", language: "en")
        external.flush()
        let bytes = defaults.data(forKey: PersonalLexiconStore.storageKey)
        XCTAssertThrowsError(try store.undo(second)) {
            XCTAssertEqual($0 as? PersonalDataStoreError, .externalChange)
        }
        store.flush()
        XCTAssertEqual(defaults.data(forKey: PersonalLexiconStore.storageKey), bytes)
        XCTAssertNotNil(store.snapshot.entries["en\u{1f}local"])
    }

    func testIndependentManualSavesCanBeUndoneSeparately() throws {
        let store = LearnedRulesStore(defaults: defaults)
        let first = try save(store)
        let second = try XCTUnwrap(store.saveManualCorrection(original: KeyMapping.convert("world"), converted: "world",
                                                               appBundleID: nil, model: LanguageModelStore.bundled))
        XCTAssertEqual(try store.undo(first.receipt), .undone)
        XCTAssertTrue(store.snapshot.isConfirmed(original: KeyMapping.convert("world"), converted: "world", appBundleID: nil))
        XCTAssertEqual(try store.undo(second.receipt), .undone)
        XCTAssertTrue(store.snapshot.rules.isEmpty)
    }

    func testCapacityConflictDoesNotEvictUnrelatedNewRules() throws {
        let now = Date()
        var rules = [AdaptiveRule(original: wrong, converted: "hello", positiveCount: 2, confirmed: true, lastUsed: now)]
        for index in 0..<1998 {
            let word = "qzvrtk\(index)"
            rules.append(AdaptiveRule(original: KeyMapping.convert(word), converted: word, positiveCount: 2, lastUsed: now))
        }
        rules.append(AdaptiveRule(original: KeyMapping.convert("stale"), converted: "stale", positiveCount: 1,
                                  lastUsed: Date(timeIntervalSince1970: 1)))
        let store = LearnedRulesStore(defaults: defaults)
        store.snapshot = AdaptiveRuleBook(rules: rules)
        let saved = try save(store)
        XCTAssertEqual(store.snapshot.rules.count, 1999)
        store.recordPositive(original: KeyMapping.convert("newcomer"), converted: "newcomer")
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        XCTAssertEqual(try store.undo(saved.receipt), .conflict)
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        XCTAssertEqual(store.snapshot.rules.count, 2000)
    }

    func testFailedUndoReadBackDoesNotReportSuccess() throws {
        let rejecting = try XCTUnwrap(RejectingDefaults(suiteName: domain))
        let store = LearnedRulesStore(defaults: rejecting)
        let saved = try save(store)
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        rejecting.rejectWrites = true
        XCTAssertThrowsError(try store.undo(saved.receipt)) {
            XCTAssertEqual($0 as? PersonalDataStoreError, .readBackFailed)
        }
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
        XCTAssertEqual(try store.undo(saved.receipt), .invalidReceipt)
    }

    func testCorruptCounterIsRejectedBeforeIncrementing() throws {
        let store = LearnedRulesStore(defaults: defaults)
        store.snapshot = AdaptiveRuleBook(rules: [AdaptiveRule(original: wrong, converted: "hello", positiveCount: Int.max)])
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        XCTAssertThrowsError(try store.saveManualCorrection(original: wrong, converted: "hello", appBundleID: nil,
                                                             model: LanguageModelStore.bundled))
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
    }

    func testCombinedPreflightDoesNotWriteOrConsumeAndUndoRechecks() throws {
        let rules = LearnedRulesStore(defaults: defaults)
        let personal = PersonalLexiconStore(defaults: defaults)
        personal.observe(word: "qzvrtk", language: "en")
        let saved = try save(rules)
        let forgotten = try XCTUnwrap(personal.removeWithReceipt(word: "qzvrtk", language: "en"))
        let ruleBytes = defaults.data(forKey: LearnedRulesStore.storageKey)
        let lexiconBytes = defaults.data(forKey: PersonalLexiconStore.storageKey)
        for _ in 0..<2 {
            XCTAssertNil(rules.validateUndo(saved.receipt))
            XCTAssertNil(personal.validateUndo(forgotten))
        }
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), ruleBytes)
        XCTAssertEqual(defaults.data(forKey: PersonalLexiconStore.storageKey), lexiconBytes)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).validateUndo(saved.receipt), .invalidReceipt)
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).validateUndo(forgotten), .invalidReceipt)

        personal.observe(word: "qzvrtk", language: "en")
        XCTAssertNil(rules.validateUndo(saved.receipt))
        XCTAssertEqual(personal.validateUndo(forgotten), .conflict)
        XCTAssertEqual(try personal.undo(forgotten), .conflict)
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), ruleBytes)
        XCTAssertEqual(defaults.data(forKey: PersonalLexiconStore.storageKey), lexiconBytes)

        _ = try save(rules)
        XCTAssertEqual(try rules.undo(saved.receipt), .conflict)
        let next = try save(rules)
        XCTAssertNil(rules.validateUndo(next.receipt))
        XCTAssertEqual(try rules.undo(next.receipt), .undone)
        XCTAssertEqual(rules.validateUndo(next.receipt), .invalidReceipt)

        personal.remove(word: "qzvrtk", language: "en")
        personal.observe(word: "other", language: "en")
        let removable = try XCTUnwrap(personal.removeWithReceipt(word: "other", language: "en"))
        XCTAssertNil(personal.validateUndo(removable))
        XCTAssertEqual(try personal.undo(removable), .undone)
        XCTAssertEqual(personal.validateUndo(removable), .invalidReceipt)
    }

    func testFullBackupOfActualWeakCountersPreservesPunctuationAndNormalization() throws {
        let store = LearnedRulesStore(defaults: defaults)
        store.recordPositive(original: " " + wrong.uppercased() + "?! ", converted: " HELLO?! ")
        store.recordPositive(original: wrong, converted: "hello")
        store.recordPositive(original: wrong + ",", converted: "hello,")
        store.recordNegative(original: KeyMapping.convert("world") + ",", converted: "WORLD,", appBundleID: "chat.one")
        store.recordPositive(original: "T;BR?", converted: "\u{0415}\u{0308}\u{0416}\u{0418}\u{041A},")
        let snapshot = LearnedRulesStore(defaults: defaults).snapshot
        XCTAssertEqual(snapshot.rules.count, 4)
        XCTAssertTrue(snapshot.learnedEntries.isEmpty)
        let hello = try XCTUnwrap(snapshot.rules.first { $0.converted == " hello?! " })
        XCTAssertEqual(hello.original, " " + wrong + "?! ")
        XCTAssertEqual(hello.positiveCount, 1)
        XCTAssertEqual(snapshot.rules.first { $0.converted == "hello" }?.positiveCount, 2)
        XCTAssertTrue(snapshot.rules.contains { $0.original == "t;br?" && $0.converted == "\u{0451}\u{0436}\u{0438}\u{043A}," })
        let archive = try PersonalDataArchive(payload: .init(
            adaptiveRules: snapshot, personalLexicon: PersonalLexicon(), userDictionary: [],
            alwaysConvertWords: [], deniedWords: [], deniedAppsAdded: [], deniedAppsRemoved: []
        ))
        let decoded = try PersonalDataArchive.decode(archive.encoded())
        XCTAssertEqual(decoded.payload.adaptiveRules, snapshot)
        try store.replace(with: decoded.payload.adaptiveRules)
        XCTAssertEqual(LearnedRulesStore(defaults: defaults).snapshot, snapshot)
    }

    func testOneLetterAutomaticFeedbackDoesNotCreatePersistableCounters() throws {
        let store = LearnedRulesStore(defaults: defaults)
        store.recordPositive(original: "b", converted: KeyMapping.convert("b"))
        XCTAssertTrue(store.snapshot.rules.isEmpty)
        let reloaded = LearnedRulesStore(defaults: defaults).snapshot
        let archive = try PersonalDataArchive(payload: .init(
            adaptiveRules: reloaded, personalLexicon: PersonalLexicon(), userDictionary: [],
            alwaysConvertWords: [], deniedWords: [], deniedAppsAdded: [], deniedAppsRemoved: []
        ))
        XCTAssertEqual(try PersonalDataArchive.decode(archive.encoded()).payload.adaptiveRules, reloaded)
    }
}

private final class RejectingDefaults: UserDefaults, @unchecked Sendable {
    var rejectWrites = false
    override func set(_ value: Any?, forKey defaultName: String) {
        if !rejectWrites { super.set(value, forKey: defaultName) }
    }
}
