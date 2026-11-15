import Foundation
import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport
@testable import RuSwitcher

final class PersonalBackupSettingsTests: XCTestCase {
    func testManualOnlyListSurvivesFullBackupAndDisablesLearningAfterRestore() throws {
        let name = "CerfSwitcher.Tests.ManualOnly.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.deniedWords = ["here"]
        let backup = try settings.exportPersonalBackup()
        settings.deniedWords = []
        try settings.restorePersonalBackup(PersonalDataArchive.decode(backup))
        let restarted = SettingsManager(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertEqual(restarted.deniedWords, ["here"])
        XCTAssertTrue(restarted.wordConversionPolicy.excludes(original: "руку", converted: "here"))
        XCTAssertNil(try restarted.saveManualLearning(original: "руку", converted: "here",
            appBundleID: "test.editor", model: LanguageModelStore.bundled))
        XCTAssertTrue(restarted.adaptiveRuleBook.rules.isEmpty)
    }

    func testBackupRestoresEveryPersonalSectionWithoutChangingGeneralSettings() throws {
        let name = "CerfSwitcher.Tests.Backup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.autoConvert = true
        settings.triggerKey = "shift"
        settings.userDictionary.add(text: "Vextora\nзорнавик")
        settings.alwaysConvertWords = ["pjd"]
        settings.deniedWords = ["brand"]
        let excluded = settings.deniedApps
        settings.deniedApps = Array(excluded.dropFirst()) + ["test.personal.editor"]
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "pfvjr", converted: "замок")
        book.recordNegative(original: "pfvjr", converted: "замок", appBundleID: "test.personal.editor")
        settings.adaptiveRuleBook = book
        _ = settings.personalLexicon.observe(word: "vextora", language: "en")
        let before = try settings.personalDataSnapshot()
        let data = try settings.exportPersonalBackup()

        settings.clearAdaptiveRules()
        settings.userDictionary.clear()
        settings.alwaysConvertWords = []
        settings.deniedWords = []
        settings.deniedApps = []
        try settings.restorePersonalBackup(PersonalDataArchive.decode(data))

        XCTAssertEqual(try settings.personalDataSnapshot(), before)
        XCTAssertTrue(settings.autoConvert)
        XCTAssertEqual(settings.triggerKey, "shift")
        let restarted = SettingsManager(defaults: defaults)
        XCTAssertEqual(try restarted.personalDataSnapshot(), before)
    }

    func testOldLearnedArchiveStillMergesWithoutRemovingExplicitWords() throws {
        let name = "CerfSwitcher.Tests.LegacyBackup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "pfvjr", converted: "замок")
        settings.adaptiveRuleBook = book
        let legacy = try settings.exportLearnedCorrections()
        settings.clearAdaptiveRules()
        settings.userDictionary.add(text: "Vextora")
        _ = try settings.importLearnedCorrections(legacy)
        XCTAssertTrue(settings.isAdaptiveConfirmed(original: "pfvjr", converted: "замок", appBundleID: nil))
        XCTAssertEqual(settings.userDictionary.words, ["Vextora"])
    }

    func testFailedRestoreAtEachStoreRestoresPreviousPersonalData() throws {
        let keys = [
            LearnedRulesStore.storageKey, PersonalLexiconStore.storageKey, UserDictionaryStore.storageKey,
            "com.ruswitcher.alwaysConvertWords", "com.ruswitcher.deniedWords",
            "com.ruswitcher.deniedAppsAdded", "com.ruswitcher.deniedAppsRemoved",
        ]
        for key in keys {
            let name = "CerfSwitcher.Tests.BackupFailure.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(RejectOneBackupWriteDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let settings = SettingsManager(defaults: defaults)
            var existing = AdaptiveRuleBook()
            existing.recordConfirmed(original: "pfvjr", converted: "замок")
            settings.adaptiveRuleBook = existing
            settings.userDictionary.add(text: "Vextora")
            settings.personalLexicon.observe(word: "vextora", language: "en")
            settings.alwaysConvertWords = ["pjd"]
            settings.deniedWords = ["brand"]
            settings.deniedApps = Array(settings.deniedApps.dropFirst()) + ["test.old.editor"]
            settings.autoConvert = true
            let before = try settings.personalDataSnapshot()

            var replacement = AdaptiveRuleBook()
            replacement.recordConfirmed(original: "руддщ", converted: "hello")
            let archive = try PersonalDataArchive(payload: .init(
                adaptiveRules: replacement, personalLexicon: PersonalLexicon(), userDictionary: ["Zenvara"],
                alwaysConvertWords: ["rnj"], deniedWords: ["project"],
                deniedAppsAdded: ["test.new.editor"], deniedAppsRemoved: []
            ))
            defaults.rejectNextKey = key
            XCTAssertThrowsError(try settings.restorePersonalBackup(archive), key)
            XCTAssertTrue(defaults.didReject, key)
            XCTAssertEqual(try settings.personalDataSnapshot(), before, key)
            XCTAssertEqual(try SettingsManager(defaults: defaults).personalDataSnapshot(), before, key)
            XCTAssertTrue(settings.autoConvert)
        }
    }
}

private final class RejectOneBackupWriteDefaults: UserDefaults, @unchecked Sendable {
    var rejectNextKey: String?
    private(set) var didReject = false

    override func set(_ value: Any?, forKey defaultName: String) {
        if rejectNextKey == defaultName {
            rejectNextKey = nil
            didReject = true
        } else {
            super.set(value, forKey: defaultName)
        }
    }
}
