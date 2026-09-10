import XCTest
@testable import RuSwitcherAppSupport

final class QueuedLayoutTransitionTests: XCTestCase {
    func testOnlyKeysAlreadyQueuedAtOwnSwitchAreTranslated() {
        var transition = QueuedLayoutTransition()
        XCTAssertNil(transition.overrideText(eventTimestamp: 90, layoutID: "ru", translatedText: "м"))
        transition.record(targetLayoutID: "ru", completedAt: 100)
        XCTAssertEqual(transition.overrideText(eventTimestamp: 90, layoutID: "ru", translatedText: "м"), "м")
        XCTAssertEqual(transition.overrideText(eventTimestamp: 100, layoutID: "ru", translatedText: "ы"), "ы")
        XCTAssertNil(transition.overrideText(eventTimestamp: 101, layoutID: "ru", translatedText: "и"))
        XCTAssertNil(transition.overrideText(eventTimestamp: 99, layoutID: "ru", translatedText: "м"))
    }

    func testEnglishAndShiftedPunctuationUseTheSameRule() {
        var transition = QueuedLayoutTransition()
        transition.record(targetLayoutID: "en", completedAt: 200)
        XCTAssertEqual(transition.overrideText(eventTimestamp: 180, layoutID: "en", translatedText: "R"), "R")
        XCTAssertEqual(transition.overrideText(eventTimestamp: 190, layoutID: "en", translatedText: "?"), "?")
    }

    func testLayoutChangeAndEditingResetCancelTheTransition() {
        var transition = QueuedLayoutTransition()
        transition.record(targetLayoutID: "ru", completedAt: 100)
        XCTAssertNil(transition.overrideText(eventTimestamp: 90, layoutID: "en", translatedText: "v"))
        XCTAssertNil(transition.overrideText(eventTimestamp: 95, layoutID: "ru", translatedText: "м"))
        transition.record(targetLayoutID: "ru", completedAt: 200)
        transition.reset()
        XCTAssertNil(transition.overrideText(eventTimestamp: 190, layoutID: "ru", translatedText: "м"))
    }

    func testUnknownTimestampsDeadKeysAndComplexTextAreNeverInjected() {
        for text: String? in [nil, "", "\n", "\u{7f}", "\u{301}", "e\u{301}", "😀", "two"] {
            var transition = QueuedLayoutTransition()
            transition.record(targetLayoutID: "ru", completedAt: 100)
            XCTAssertNil(transition.overrideText(eventTimestamp: 90, layoutID: "ru", translatedText: text))
            XCTAssertNil(transition.overrideText(eventTimestamp: 95, layoutID: "ru", translatedText: "м"))
        }
        var transition = QueuedLayoutTransition()
        transition.record(targetLayoutID: "ru", completedAt: 100)
        XCTAssertNil(transition.overrideText(eventTimestamp: 0, layoutID: "ru", translatedText: "м"))
    }
}
