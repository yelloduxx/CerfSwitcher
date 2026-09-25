import Foundation
import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport
import RuSwitcherTestSupport

@MainActor
final class LearnedRulesStoreTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        domain = "com.ruswitcher.tests.learning.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    func testNewLabelChangesPhraseBehaviorAndSurvivesReloadExportResetAndImport() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let word = "tilomeraq"
        let wrong = KeyMapping.convert(word)
        XCTAssertFalse(model.contains(word, language: "en") || model.isExtendedEnglishWord(word))
        XCTAssertFalse(model.contains(wrong, language: "ru") || model.isExtendedRussianWord(wrong))
        let store = LearnedRulesStore(defaults: defaults)
        defaults.set("untouched", forKey: "unrelated-setting")
        let literal = "в этом проекте мы используем \(wrong) for the next draft, and then we discuss it. "
        let corrected = "в этом проекте мы используем \(word) for the next draft, and then we discuss it. "
        XCTAssertEqual(try phrase(store: store, app: "editor.first", word: word).text, literal)
        XCTAssertEqual(store.recordManualCorrection(original: wrong, converted: word, appBundleID: "editor.first", model: model),
                       .confirmation(original: wrong, converted: word, clearingExceptionFor: "editor.first"))
        let after = try phrase(store: store, app: "editor.second", word: word)
        XCTAssertEqual(after.text, corrected)
        XCTAssertEqual(after.transactions, 1)
        XCTAssertNotNil(defaults.data(forKey: LearnedRulesStore.storageKey))

        // A fresh defaults/store object tests persisted bytes, not the original
        // in-memory rule book. This is not a native app/process restart claim.
        let reloaded = LearnedRulesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)))
        XCTAssertEqual(try phrase(store: reloaded, app: "editor.second", word: word).text, corrected)
        let archive = try reloaded.exportRules()
        reloaded.clear()
        XCTAssertEqual(try phrase(store: reloaded, app: "editor.second", word: word).text, literal)
        XCTAssertEqual(defaults.string(forKey: "unrelated-setting"), "untouched")
        XCTAssertEqual(try reloaded.importRules(archive).added, 1)
        let restored = reloaded.snapshot
        XCTAssertEqual(try reloaded.importRules(archive).added, 0)
        XCTAssertEqual(reloaded.snapshot, restored)
        XCTAssertEqual(try phrase(store: reloaded, app: "editor.second", word: word).text, corrected)
    }

    func testApplicationExceptionIsPortableAndReaffirmingClearsOnlyThatApplication() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let word = "tilomeraq"
        let wrong = KeyMapping.convert(word)
        let store = LearnedRulesStore(defaults: defaults)
        _ = store.recordManualCorrection(original: wrong, converted: word, appBundleID: "editor.first", model: model)
        for app in ["editor.second", "editor.third"] {
            XCTAssertEqual(store.recordManualCorrection(original: word, converted: wrong, appBundleID: app, model: model),
                           .applicationException(original: wrong, converted: word, appBundleID: app))
        }
        let archive = try store.exportRules()
        store.clear()
        _ = try store.importRules(archive)
        let corrected = "в этом проекте мы используем \(word) for the next draft, and then we discuss it. "
        let literal = "в этом проекте мы используем \(wrong) for the next draft, and then we discuss it. "
        XCTAssertEqual(try phrase(store: store, app: "editor.first", word: word).text, corrected)
        let excepted = try phrase(store: store, app: "editor.second", word: word)
        XCTAssertEqual(excepted.text, literal)
        XCTAssertEqual(excepted.transactions, 0)
        _ = store.recordManualCorrection(original: wrong + " ", converted: word + " ", appBundleID: "editor.second", model: model)
        XCTAssertEqual(try phrase(store: store, app: "editor.second", word: word).text, corrected)
        XCTAssertTrue(store.snapshot.hasApplicationException(original: wrong, converted: word, appBundleID: "editor.third"))
        XCTAssertFalse(store.snapshot.rules.contains { $0.original == word && $0.converted == wrong })
    }

    func testInvalidImportAndRejectedManualFeedbackLeavePersistedDataUnchanged() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        let store = LearnedRulesStore(defaults: defaults)
        _ = store.recordManualCorrection(original: "cnhfybwf", converted: "страница", appBundleID: "editor.first", model: model)
        let before = defaults.data(forKey: LearnedRulesStore.storageKey)
        XCTAssertThrowsError(try store.importRules(Data("{broken".utf8)))
        XCTAssertEqual(store.recordManualCorrection(original: "someCode", converted: "ыщьуСщву", appBundleID: "editor.first", model: model), .ignore)
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), before)
    }

    func testReadsExistingStorageFormatAndSerializesConcurrentUpdates() throws {
        let book = AdaptiveRuleBook(rules: [.init(original: "cnhfybwf", converted: "страница", positiveCount: 1, confirmed: true)])
        let data = try JSONEncoder().encode(book)
        defaults.set(data, forKey: "com.ruswitcher.adaptiveRules.v1")
        let store = LearnedRulesStore(defaults: defaults)
        XCTAssertEqual(store.snapshot, book)
        XCTAssertEqual(defaults.data(forKey: LearnedRulesStore.storageKey), data)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            store.recordPositive(original: "cnhfybwf", converted: "страница")
        }
        XCTAssertEqual(store.snapshot.rules.first?.positiveCount, 17)
    }

    private func phrase(store: LearnedRulesStore, app: String, word: String) throws -> PhysicalTypingExecution {
        let en = "com.apple.keylayout.US", ru = "com.apple.keylayout.RussianWin"
        let layouts = try SystemTypingLayouts(ids: [en, ru])
        var compiler = PhysicalTypingCompiler(layouts: layouts)
        try compiler.append(text: "в этом проекте мы используем ", intendedLayoutID: ru)
        try compiler.append(text: word + " ", intendedLayoutID: en)
        try compiler.selectLayout(en)
        try compiler.append(text: "for the next draft, and then we discuss it. ", intendedLayoutID: en)
        let stimulus = PhysicalTypingStimulus(id: "persisted-label-in-phrase", layoutIDs: [en, ru], initialLayoutID: ru,
                                             actions: compiler.actions)
        return try PhysicalTypingRunner(layouts: layouts, model: XCTUnwrap(LanguageModelStore.bundled),
                                         adaptiveRules: store.snapshot, appBundleID: app).run(stimulus)
    }
}
