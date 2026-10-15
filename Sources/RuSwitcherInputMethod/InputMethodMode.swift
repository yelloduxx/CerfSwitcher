import Carbon
import Foundation

enum InputMethodMode: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    static let bundleIdentifier = "com.cerfswitcher.inputmethod"

    var sourceID: String {
        "\(Self.bundleIdentifier).\(rawValue)"
    }

    var opposite: InputMethodMode {
        self == .english ? .russian : .english
    }

    static func current(fallback: InputMethodMode = .english) -> InputMethodMode {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return fallback }
        let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return allCases.first(where: { $0.sourceID == identifier }) ?? fallback
    }

    @discardableResult
    func select() -> Bool {
        let conditions = [
            kTISPropertyInputSourceID as String: sourceID,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(conditions, true)?.takeRetainedValue()
                as? [TISInputSource],
              let source = sources.first
        else { return false }
        return TISEnableInputSource(source) == noErr && TISSelectInputSource(source) == noErr
    }
}
