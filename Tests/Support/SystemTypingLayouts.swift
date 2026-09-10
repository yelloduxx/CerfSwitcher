import Carbon
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

public struct SystemTypingLayout: Sendable {
    public let id: String
    public let language: String
    public let data: Data
}

/// Read-only layout loading. No input source is selected on the user's desktop.
public struct SystemTypingLayouts: Sendable {
    public let entries: [String: SystemTypingLayout]

    public init(ids: [String]) throws {
        var loaded: [String: SystemTypingLayout] = [:]
        for id in ids {
            // An offline translation test need not enable the source in Settings.
            // Filter narrowly so includeAllInstalled does not load every IME.
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
                  let source = sources.first(where: { Self.id(of: $0) == id }),
                  let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
                  let languagesPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
                throw PhysicalTypingError.unavailableLayout(id)
            }
            let languages = Unmanaged<CFArray>.fromOpaque(languagesPointer).takeUnretainedValue() as? [String]
            guard let language = languages?.first else { throw PhysicalTypingError.unavailableLayout(id) }
            let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
            loaded[id] = SystemTypingLayout(id: id, language: LanguageCode.canonical(language), data: data)
        }
        entries = loaded
    }

    public func layout(_ id: String) throws -> SystemTypingLayout {
        guard let layout = entries[id] else { throw PhysicalTypingError.unavailableLayout(id) }
        return layout
    }

    /// Uses a fresh dead-key state. Composition is interpreted by the runner's
    /// persistent state; this helper compiles unambiguous fixture strokes only.
    public func character(keyCode: UInt16, shift: Bool, capsLock: Bool = false, layoutID: String, keyboardType: UInt32 = 40) throws -> String {
        let layout = try layout(layoutID)
        var state = KeyboardLayoutTranslationState()
        guard let text = state.translate(
            keyCode: keyCode, shift: shift, capsLock: capsLock,
            layoutData: layout.data, keyboardType: keyboardType
        ) else { throw PhysicalTypingError.unrepresentableText("keycode=\(keyCode)", layoutID) }
        return text
    }

    private static func id(of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

/// Compiles authored text to physical strokes before a run. The selected layout
/// here expresses the author's intended keys, not a command to switch at runtime.
public struct PhysicalTypingCompiler {
    private let layouts: SystemTypingLayouts
    private let keyboardType: UInt32
    public private(set) var actions: [PhysicalTypingAction] = []
    private var time: UInt64 = 0

    public init(layouts: SystemTypingLayouts, keyboardType: UInt32 = 40) {
        self.layouts = layouts
        self.keyboardType = keyboardType
    }

    public mutating func append(text: String, intendedLayoutID: String, intervalMicroseconds: UInt64 = 70_000) throws {
        guard intervalMicroseconds >= 2 else { throw PhysicalTypingError.invalidScenario("key interval must be >= 2 microseconds") }
        _ = try layouts.layout(intendedLayoutID)
        for character in text {
            let (next, overflow) = time.addingReportingOverflow(intervalMicroseconds)
            guard !overflow else { throw PhysicalTypingError.invalidScenario("event time overflow") }
            let stroke: (UInt16, Bool)
            switch character {
            case " ": stroke = (49, false)
            case "\n": stroke = (36, false)
            case "\t": stroke = (48, false)
            default:
                var found: (UInt16, Bool)?
                // ANSI/ISO printable positions; never guess a keycode on a miss.
                for shift in [false, true] {
                    for keyCode in Array(UInt16(0)...50) + [UInt16(93), 94, 10] {
                        if try layouts.character(
                            keyCode: keyCode, shift: shift, layoutID: intendedLayoutID, keyboardType: keyboardType
                        ) == String(character) {
                            found = (keyCode, shift)
                            break
                        }
                    }
                    if found != nil { break }
                }
                guard let found else { throw PhysicalTypingError.unrepresentableText(String(character), intendedLayoutID) }
                stroke = found
            }
            actions.append(.init(kind: .keyDown, atMicroseconds: time, keyCode: stroke.0, shift: stroke.1))
            actions.append(.init(kind: .keyUp, atMicroseconds: time + intervalMicroseconds / 3, keyCode: stroke.0, shift: stroke.1))
            time = next
        }
    }

    public mutating func selectLayout(_ id: String) throws {
        _ = try layouts.layout(id)
        actions.append(.init(kind: .selectLayout, atMicroseconds: time, layoutID: id))
    }
}
