import RuSwitcherCore

public enum InputEventDisposition: Equatable, Sendable {
    case suppress
    case track(InputEvent)
}

public enum SpaceKeyDisposition: Equatable, Sendable {
    case notSpaceKey
    case boundary
    case textComposition
}

public enum LocalKeyDisposition: Equatable, Sendable {
    case boundary(InputBoundary)
    case compositionCommit
    case editing(InputEvent)
    case printable(TypedKey)
}

public enum InputEventClassifier {
    /// Classifies local physical keyDown events only. Remote Unicode input must
    /// be dispatched separately; local key code zero is an ordinary mapped key.
    public static func classifyLocalKeyDown(
        key: TypedKey,
        command: Bool,
        control: Bool,
        option: Bool
    ) -> LocalKeyDisposition {
        // Composition and structural boundaries precede even stale modifiers.
        switch classifySpaceKey(isSpaceKey: key.keyCode == LocalKeyCode.space, producedText: key.producedText) {
        case .textComposition:
            return .compositionCommit
        case .boundary:
            return .boundary(.space(count: 1))
        case .notSpaceKey:
            break
        }

        if key.keyCode == LocalKeyCode.enter { return .boundary(.enter) }
        if key.keyCode == LocalKeyCode.tab { return .boundary(.tab) }

        if (LocalKeyCode.left...LocalKeyCode.up).contains(key.keyCode)
            || [LocalKeyCode.home, LocalKeyCode.end, LocalKeyCode.pageUp, LocalKeyCode.pageDown].contains(key.keyCode) {
            return .editing(.navigation)
        }

        let hasEditingModifier = command || control || option
        if key.keyCode == LocalKeyCode.backspace || key.keyCode == LocalKeyCode.deleteForward {
            return .editing(hasEditingModifier || key.keyCode == LocalKeyCode.deleteForward
                ? .modifiedDeletion : .plainBackspace)
        }

        if hasEditingModifier {
            if command, key.keyCode == LocalKeyCode.letterZ {
                return .editing(.undo)
            }
            if command, [LocalKeyCode.letterA, LocalKeyCode.letterC, LocalKeyCode.letterV, LocalKeyCode.letterX].contains(key.keyCode) {
                return .editing(.clipboardCommand)
            }
            return .editing(.navigation)
        }

        if KeyMapping.keycodeToEN[key.keyCode] != nil {
            return .printable(key)
        }
        // Unrecognized local keys clear context just like navigation, rather
        // than trusting a Unicode payload to turn them into printable input.
        return .editing(.navigation)
    }

    /// A physical Space key is not necessarily a text boundary. On dead-key
    /// layouts, Space can commit a quote or accent and the event's Unicode
    /// payload contains that character instead of whitespace.
    public static func classifySpaceKey(
        isSpaceKey: Bool,
        producedText: String?
    ) -> SpaceKeyDisposition {
        guard isSpaceKey else { return .notSpaceKey }
        guard let producedText, !producedText.isEmpty else {
            return .boundary
        }
        return producedText == " " ? .boundary : .textComposition
    }

    public static func classifyRemoteAutorepeat(
        activeTap: Bool,
        key: TypedKey
    ) -> InputEventDisposition {
        activeTap ? .suppress : .track(.printable(key))
    }

    private enum LocalKeyCode {
        static let letterA: UInt16 = 0
        static let letterZ: UInt16 = 6
        static let letterX: UInt16 = 7
        static let letterC: UInt16 = 8
        static let letterV: UInt16 = 9
        static let enter: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let deleteForward: UInt16 = 117
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let left: UInt16 = 123
        static let up: UInt16 = 126
    }
}
