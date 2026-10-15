import Foundation
import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport

final class UserDictionaryStoreTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        domain = "com.ruswitcher.tests.userdictionary.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    func testWordsSurviveReloadRemovalAndClear() {
        let store = UserDictionaryStore(defaults: defaults)
        XCTAssertEqual(store.add(text: "Figma\nкринж, Nuxt 42"), UserDictionary.Report(added: 3, duplicates: 0, invalid: 1, overLimit: 0))
        XCTAssertEqual(defaults.stringArray(forKey: UserDictionaryStore.storageKey), ["Figma", "кринж", "Nuxt"])
        let reloaded = UserDictionaryStore(defaults: defaults)
        XCTAssertTrue(reloaded.contains("FIGMA"))
        XCTAssertFalse(reloaded.contains("Tesla"))
        XCTAssertEqual(reloaded.words, ["Figma", "кринж", "Nuxt"])
        XCTAssertEqual(reloaded.wordsByLanguage, ["en": ["figma", "nuxt"], "ru": ["кринж"]])
        reloaded.remove(["figma"])
        XCTAssertEqual(UserDictionaryStore(defaults: defaults).words, ["кринж", "Nuxt"])
        reloaded.clear()
        XCTAssertNil(defaults.stringArray(forKey: UserDictionaryStore.storageKey))
        XCTAssertEqual(UserDictionaryStore(defaults: defaults).words, [])
    }
}
