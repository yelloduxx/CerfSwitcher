import XCTest
@testable import RuSwitcherCore

final class PhysicalKeyboardMappingTests: XCTestCase {
    func testLettersRespectLanguageShiftAndCapsLock() {
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 3, language: "en", shift: false, capsLock: false
        ), "f")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 3, language: "ru", shift: false, capsLock: false
        ), "а")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 3, language: "ru", shift: true, capsLock: false
        ), "А")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 3, language: "ru", shift: true, capsLock: true
        ), "а")
    }

    func testQuestionCommaAndNumberRowUsePhysicalRussianLayout() {
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 44, language: "en", shift: true, capsLock: false
        ), "?")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 44, language: "ru", shift: true, capsLock: false
        ), ",")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 26, language: "en", shift: true, capsLock: false
        ), "&")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 26, language: "ru", shift: true, capsLock: false
        ), "?")
        XCTAssertEqual(KeyMapping.producedText(
            keyCode: 20, language: "ru", shift: true, capsLock: false
        ), "№")
    }

    func testUnsupportedLanguageDoesNotGuess() {
        XCTAssertNil(KeyMapping.producedText(
            keyCode: 3, language: "zh", shift: false, capsLock: false
        ))
    }
}
