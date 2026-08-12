import AppKit
import Carbon
import InputMethodKit
import RuSwitcherCore

@objc(RuSwitcherInputController)
final class RuSwitcherInputController: IMKInputController {
    private static let noReplacementRange = NSRange(location: NSNotFound, length: NSNotFound)
    private static let shiftKeyCodes: Set<UInt16> = [56, 60]
    private static let manualTapWindow: TimeInterval = 0.45

    private let model = LanguageModelStore.bundled
    private let preferences = InputMethodPreferencesStore()
    private var composition: InputMethodCompositionSession?
    private var mode = InputMethodMode.current()
    private var shiftPressedAlone = false
    private var shiftPressedAt: TimeInterval?
    private var lastShiftTapAt: TimeInterval?
    private var pendingLearning: (original: String, converted: String, appBundleID: String?)?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        if let model {
            composition = InputMethodCompositionSession(
                currentLanguage: mode.rawValue,
                model: model
            )
        }
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    @objc(handleEvent:client:)
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        if event.type == .flagsChanged {
            return handleFlagsChanged(event, sender: sender)
        }
        guard event.type == .keyDown else { return false }
        guard composition != nil, inputClient(sender) != nil else { return false }

        let commandModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .function,
        ])
        let cancelsLearning: Set<UInt16> = [51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126]
        if !commandModifiers.isEmpty || cancelsLearning.contains(event.keyCode) {
            pendingLearning = nil
        } else {
            confirmPendingLearning()
        }
        if !commandModifiers.isEmpty {
            commitResolved(sender)
            return false
        }

        let currentMode = InputMethodMode.current(fallback: mode)
        if currentMode != mode {
            commitResolved(sender)
            mode = currentMode
            composition?.beginLanguage(mode.rawValue)
        }

        switch event.keyCode {
        case 51:
            guard composition?.deleteBackward() == true else { return false }
            updateMarkedText(sender)
            return true
        case 36, 48, 49, 76:
            commitResolved(sender)
            return false
        case 53, 115, 116, 117, 119, 121, 123, 124, 125, 126:
            commitResolved(sender)
            return false
        default:
            break
        }

        let flags = event.modifierFlags
        guard let text = KeyMapping.producedText(
            keyCode: event.keyCode,
            language: mode.rawValue,
            shift: flags.contains(.shift),
            capsLock: flags.contains(.capsLock)
        ) else { return false }

        if IsSecureEventInputEnabled() {
            commitLiteral(sender)
            inputClient(sender)?.insertText(text, replacementRange: Self.noReplacementRange)
            return true
        }

        composition?.append(text, capsLock: flags.contains(.capsLock))
        updateMarkedText(sender)
        return true
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func commitComposition(_ sender: Any!) {
        commitResolved(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        commitResolved(sender)
        super.deactivateServer(sender)
    }

    private func inputClient(_ sender: Any?) -> (any IMKTextInput)? {
        sender as? any IMKTextInput
    }

    private func updateMarkedText(_ sender: Any?) {
        guard let composition, let client = inputClient(sender) else { return }
        let length = composition.token.utf16.count
        client.setMarkedText(
            composition.token,
            selectionRange: NSRange(location: length, length: 0),
            replacementRange: Self.noReplacementRange
        )
    }

    private func commitResolved(_ sender: Any?) {
        guard var composition, let client = inputClient(sender) else { return }
        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let resolution = composition.resolve(
            preferences: preferences.snapshot(appBundleID: appBundleID)
        ) else { return }
        self.composition = composition
        client.insertText(resolution.replacement, replacementRange: Self.noReplacementRange)
        if resolution.wasConverted {
            mode = resolution.resolvedLanguage == "ru" ? .russian : .english
            _ = mode.select()
        }
    }

    private func commitLiteral(_ sender: Any?) {
        guard var composition, let client = inputClient(sender),
              let literal = composition.takeLiteralWithoutContext()
        else { return }
        self.composition = composition
        client.insertText(literal, replacementRange: Self.noReplacementRange)
    }

    private func handleFlagsChanged(_ event: NSEvent, sender: Any?) -> Bool {
        guard Self.shiftKeyCodes.contains(event.keyCode) else {
            shiftPressedAlone = false
            return false
        }
        let now = event.timestamp
        if event.modifierFlags.contains(.shift) {
            let otherModifiers = event.modifierFlags.intersection([.command, .control, .option])
            shiftPressedAlone = otherModifiers.isEmpty
            shiftPressedAt = now
            return false
        }

        defer {
            shiftPressedAlone = false
            shiftPressedAt = nil
        }
        guard shiftPressedAlone, let pressedAt = shiftPressedAt,
              now - pressedAt < Self.manualTapWindow
        else { return false }

        if let last = lastShiftTapAt, now - last < Self.manualTapWindow {
            lastShiftTapAt = nil
            pendingLearning = nil
            return forceToggle(sender)
        }
        lastShiftTapAt = now
        return false
    }

    private func forceToggle(_ sender: Any?) -> Bool {
        guard let client = inputClient(sender) else { return false }
        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if var composition, let result = composition.forceToggle() {
            self.composition = composition
            client.insertText(result.replacement, replacementRange: Self.noReplacementRange)
            pendingLearning = (result.original, result.replacement, appBundleID)
            mode = result.resolvedLanguage == "ru" ? .russian : .english
            _ = mode.select()
            return true
        }

        guard let target = manualReplacementTarget(client: client) else { return false }
        client.insertText(target.replacement, replacementRange: target.range)
        pendingLearning = (target.original, target.convertedWord, appBundleID)
        let language = SmartTokenizer.languageHint(for: target.convertedWord)
        if language == "ru" {
            mode = .russian
            _ = mode.select()
        } else if language == "en" {
            mode = .english
            _ = mode.select()
        }
        return true
    }

    private func manualReplacementTarget(
        client: any IMKTextInput
    ) -> (range: NSRange, original: String, convertedWord: String, replacement: String)? {
        let selected = client.selectedRange()
        guard selected.location != NSNotFound, selected.length != NSNotFound else { return nil }

        if selected.length > 0 {
            guard let original = client.attributedSubstring(from: selected)?.string else { return nil }
            let converted = KeyMapping.convert(original)
            guard converted != original else { return nil }
            return (selected, original, converted, converted)
        }

        let lookback = min(192, selected.location)
        guard lookback > 0 else { return nil }
        let readRange = NSRange(location: selected.location - lookback, length: lookback)
        guard let suffix = client.attributedSubstring(from: readRange)?.string,
              let parsed = CaretTokenParser.tokenBeforeCaret(
                from: suffix,
                tokenAtInputStartIsComplete: readRange.location == 0
              )
        else { return nil }
        let converted = KeyMapping.convert(parsed.word)
        guard converted != parsed.word else { return nil }
        let replacedSuffix = parsed.word + parsed.trailingWhitespace
        let length = replacedSuffix.utf16.count
        guard length <= selected.location else { return nil }
        return (
            NSRange(location: selected.location - length, length: length),
            parsed.word,
            converted,
            converted + parsed.trailingWhitespace
        )
    }

    private func confirmPendingLearning() {
        guard let pendingLearning else { return }
        preferences.recordManualCorrection(
            original: pendingLearning.original,
            converted: pendingLearning.converted,
            appBundleID: pendingLearning.appBundleID
        )
        self.pendingLearning = nil
    }
}
