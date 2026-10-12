import Foundation
import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport

final class PersonalLexiconStoreTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        domain = "com.ruswitcher.tests.personal.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    func testPromotedWordsSurviveFlushAndReloadAndClear() {
        let store = PersonalLexiconStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(store.observe(word: "ок", language: "ru", at: start))
        XCTAssertFalse(store.observe(word: "ок", language: "ru", at: start.addingTimeInterval(700)))
        XCTAssertTrue(store.observe(word: "ок", language: "ru", at: start.addingTimeInterval(1_400)))
        XCTAssertNil(defaults.data(forKey: PersonalLexiconStore.storageKey), "writes wait for flush")
        store.flush()
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).promotedWordsByLanguage["ru"], ["ок"])
        XCTAssertTrue(store.remove(word: "ок", language: "ru"))
        store.flush()
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).promotedWordsByLanguage["ru"], [])
        store.observe(word: "кринж", language: "ru", at: start)
        store.clear()
        store.flush()
        XCTAssertNil(defaults.data(forKey: PersonalLexiconStore.storageKey))
        XCTAssertEqual(PersonalLexiconStore(defaults: defaults).entryCount, 0)
    }
}
