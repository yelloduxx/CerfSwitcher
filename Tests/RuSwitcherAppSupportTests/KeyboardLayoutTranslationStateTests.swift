import Carbon
import XCTest
@testable import RuSwitcherAppSupport

final class KeyboardLayoutTranslationStateTests: XCTestCase {
    func testUSInternationalQuoteIsCommittedBySpace() throws {
        guard let layoutData = usInternationalLayoutData() else {
            throw XCTSkip("US International-PC is not installed")
        }
        var state = KeyboardLayoutTranslationState()

        XCTAssertEqual(
            state.translate(keyCode: 39, shift: true, capsLock: false, layoutData: layoutData),
            ""
        )
        XCTAssertEqual(
            state.translate(keyCode: 49, shift: false, capsLock: false, layoutData: layoutData),
            "\""
        )
        XCTAssertEqual(
            state.translate(keyCode: 0, shift: false, capsLock: false, layoutData: layoutData),
            "a"
        )
        XCTAssertEqual(
            state.translate(keyCode: 49, shift: false, capsLock: false, layoutData: layoutData),
            " "
        )
    }

    private func usInternationalLayoutData() -> Data? {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.USInternational-PC"] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

}
