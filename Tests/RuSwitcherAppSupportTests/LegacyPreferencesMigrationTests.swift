import Foundation
import XCTest
import RuSwitcherAppSupport

final class LegacyPreferencesMigrationTests: XCTestCase {
    private var legacyDomain = ""
    private var targetDomain = ""
    private var legacy: UserDefaults!
    private var target: UserDefaults!

    override func setUp() async throws {
        let run = UUID().uuidString
        legacyDomain = "com.ruswitcher.tests.migration.legacy.\(run)"
        targetDomain = "com.ruswitcher.tests.migration.target.\(run)"
        legacy = try XCTUnwrap(UserDefaults(suiteName: legacyDomain))
        target = try XCTUnwrap(UserDefaults(suiteName: targetDomain))
    }

    override func tearDown() async throws {
        legacy.removePersistentDomain(forName: legacyDomain)
        target.removePersistentDomain(forName: targetDomain)
        legacy = nil
        target = nil
    }

    private func migrate() -> LegacyPreferencesMigration.Outcome {
        LegacyPreferencesMigration.run(legacyDomain: legacyDomain, targetDomain: targetDomain, into: target)
    }

    func testCopiesEveryLegacyKeyWithItsTypeAndKeepsTheLegacyDomain() throws {
        let rules = Data("[{\"source\":\"ghbdtn\",\"target\":\"привет\"}]".utf8)
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        legacy.set(rules, forKey: LearnedRulesStore.storageKey)
        legacy.set(true, forKey: "com.ruswitcher.autoConvert")
        legacy.set("en", forKey: "com.ruswitcher.interfaceLanguage")
        legacy.set(["dota", "lol"], forKey: "com.ruswitcher.deniedWords")
        legacy.set(3, forKey: "com.ruswitcher.someCounter")
        legacy.set(checked, forKey: "com.ruswitcher.lastUpdateCheck")

        XCTAssertEqual(migrate(), .copied(keys: 6))

        XCTAssertEqual(target.data(forKey: LearnedRulesStore.storageKey), rules)
        XCTAssertEqual(target.object(forKey: "com.ruswitcher.autoConvert") as? Bool, true)
        XCTAssertEqual(target.string(forKey: "com.ruswitcher.interfaceLanguage"), "en")
        XCTAssertEqual(target.stringArray(forKey: "com.ruswitcher.deniedWords"), ["dota", "lol"])
        XCTAssertEqual(target.object(forKey: "com.ruswitcher.someCounter") as? Int, 3)
        XCTAssertEqual(target.object(forKey: "com.ruswitcher.lastUpdateCheck") as? Date, checked)
        XCTAssertEqual(target.object(forKey: LegacyPreferencesMigration.markerKey) as? Bool, true)
        XCTAssertEqual(legacy.persistentDomain(forName: legacyDomain)?.count, 6)
        XCTAssertEqual(legacy.string(forKey: "com.ruswitcher.interfaceLanguage"), "en")
    }

    func testSecondRunChangesNothingEvenWhenTheLegacyDomainChanged() throws {
        legacy.set("ru", forKey: "com.ruswitcher.interfaceLanguage")
        XCTAssertEqual(migrate(), .copied(keys: 1))
        target.set("en", forKey: "com.ruswitcher.interfaceLanguage")
        legacy.set(["dota"], forKey: "com.ruswitcher.deniedWords")
        let before = try XCTUnwrap(target.persistentDomain(forName: targetDomain)) as NSDictionary

        XCTAssertEqual(migrate(), .alreadyMigrated)

        XCTAssertEqual(target.persistentDomain(forName: targetDomain) as NSDictionary?, before)
        XCTAssertEqual(target.string(forKey: "com.ruswitcher.interfaceLanguage"), "en")
        XCTAssertNil(target.object(forKey: "com.ruswitcher.deniedWords"))
    }

    func testWithoutLegacyDomainNothingIsWritten() {
        XCTAssertEqual(migrate(), .noLegacyDomain)
        XCTAssertNil(target.persistentDomain(forName: targetDomain))
        XCTAssertNil(target.object(forKey: LegacyPreferencesMigration.markerKey))
    }

    func testKeysAlreadyInTheTargetDomainWin() {
        target.set("en", forKey: "com.ruswitcher.interfaceLanguage")
        legacy.set("ru", forKey: "com.ruswitcher.interfaceLanguage")
        legacy.set(false, forKey: "com.ruswitcher.keySound")

        XCTAssertEqual(migrate(), .copied(keys: 1))

        XCTAssertEqual(target.string(forKey: "com.ruswitcher.interfaceLanguage"), "en")
        XCTAssertEqual(target.object(forKey: "com.ruswitcher.keySound") as? Bool, false)
    }
}
