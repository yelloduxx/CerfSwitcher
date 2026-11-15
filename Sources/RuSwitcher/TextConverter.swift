import AppKit
import ApplicationServices
import CoreGraphics
import RuSwitcherAppSupport
import RuSwitcherCore

enum SelectedTextConversionOutcome: Equatable {
    case none
    case converted
    case postedUnverified
    case blocked(ConversionRefusal)
    case failed

    static func unreadableSelection(selectionKnown: Bool) -> Self {
        selectionKnown ? .blocked(.fieldUnavailable) : .none
    }

    init(verification: ReplacementVerification) {
        switch verification {
        case .match: self = .converted
        case .unavailable: self = .postedUnverified
        case let .notAttempted(reason): self = .blocked(reason)
        case .unchanged, .mismatch: self = .failed
        }
    }
}

enum ManualSuffixReplacementOutcome: Equatable {
    case verified
    case postedUnverified
    case blocked(ConversionRefusal)
    case failed

    init(verification: ReplacementVerification) {
        switch verification {
        case .match: self = .verified
        case .unavailable: self = .postedUnverified
        case let .notAttempted(reason): self = .blocked(reason)
        case .unchanged, .mismatch: self = .failed
        }
    }
}

struct BufferedManualConversion {
    let original: String
    let replacement: String
    let sourceLayoutID: String?
}

struct BufferedManualReconversion {
    let current: String
    let replacement: String
    let targetLayoutID: String?
    var focus: FocusedElementIdentity? = nil
    var expectedCaretLocation: Int? = nil
}

struct CaretWordConversion {
    let original: String
    let replacement: String
    let expectedSuffix: String
    let elementIdentifier: String
    let caretLocation: Int
    let sourceLayoutID: String?
    let targetLayoutID: String?
}

enum CaretWordPreparationOutcome {
    case conversion(CaretWordConversion)
    case noCandidate
    case busy
    case blocked(ConversionRefusal)
}

enum ReplacementVerification: Equatable, Sendable {
    case match
    case unchanged
    case mismatch
    case unavailable
    case notAttempted(ConversionRefusal)
}

struct ManualReplacementEvidence: Sendable {
    static let maximumDocumentUTF16Length = 64 * 1024
    let document: String
    let range: NSRange

    init?(document: String?, original: String, range: NSRange) {
        guard let document, document.utf16.count <= Self.maximumDocumentUTF16Length,
              range.location >= 0, range.length > 0,
              range.location <= document.utf16.count,
              range.length <= document.utf16.count - range.location,
              (document as NSString).substring(with: range).utf16.elementsEqual(original.utf16) else {
            return nil
        }
        self.document = document
        self.range = range
    }

    static func readBoundedDocument(characterCount: Int?, readValue: () -> String?) -> String? {
        guard let characterCount, (0...maximumDocumentUTF16Length).contains(characterCount),
              let value = readValue(), value.utf16.count == characterCount else { return nil }
        return value
    }

    func verify(_ actual: String?, replacement: String) -> ReplacementVerification {
        guard let actual else { return .unavailable }
        let expected = (document as NSString).replacingCharacters(in: range, with: replacement)
        if actual.utf16.elementsEqual(expected.utf16) { return .match }
        if actual.utf16.elementsEqual(document.utf16) { return .unchanged }
        return .mismatch
    }
}

struct ManualOperationOwnership {
    private(set) var activeID: UUID?

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    func owns(_ id: UUID) -> Bool { activeID == id }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard owns(id) else { return false }
        activeID = nil
        return true
    }

    mutating func cancel() { activeID = nil }
}

enum ManualMutationSafety {
    static func perform(
        validation: () -> ConversionRefusal?,
        refusal: () -> ConversionRefusal?,
        mutation: () -> ReplacementVerification
    ) -> ReplacementVerification {
        if let reason = validation() { return .notAttempted(reason) }
        if let reason = refusal() { return .notAttempted(reason) }
        return mutation()
    }

    static func matchesSelectionText(_ actual: String?, expected: String, range: NSRange) -> Bool {
        guard let actual, !expected.isEmpty,
              range.location >= 0, range.length > 0, range.location <= Int.max - range.length,
              range.length == expected.utf16.count else { return false }
        return actual.utf16.elementsEqual(expected.utf16)
    }
}

private struct CaretPrefix: Sendable {
    let text: String
    let beginsAtDocumentStart: Bool
    let elementIdentifier: String
    let caretLocation: Int
}

private enum CaretPrefixRead: Sendable {
    case value(CaretPrefix)
    case blocked(ConversionRefusal)
}

private struct PhysicalReplacementStroke: Sendable {
    let keyCode: UInt16
    let shift: Bool
}

/// Конвертация текста между раскладками
@MainActor
final class TextConverter {
    private var operations = ManualOperationOwnership()
    private var isConverting: Bool { operations.activeID != nil }
    nonisolated private let manualQueue = DispatchQueue(label: "com.ruswitcher.manual-ax", qos: .userInitiated)
    nonisolated private let focusedElementResolver: NativeFocusedEditableResolver

    private final class SelectionSnapshot: @unchecked Sendable {
        let processID: pid_t
        let identifier: String
        let range: CFRange
        let text: String
        let evidence: ManualReplacementEvidence?
        let bundleID: String?

        init(processID: pid_t, identifier: String, range: CFRange, text: String,
             document: String?, bundleID: String? = nil) {
            self.processID = processID
            self.identifier = identifier
            self.range = range
            self.text = text
            self.evidence = ManualReplacementEvidence(document: document, original: text,
                range: NSRange(location: range.location, length: range.length))
            self.bundleID = bundleID
        }
    }

    @MainActor private final class ManualCompletionBox {
        let operationID: UUID
        let callback: (SelectedTextConversionOutcome) -> Void
        let processID: pid_t
        let isCurrent: @MainActor @Sendable () -> Bool
        var identifier: String?
        var range: CFRange?
        var attemptedEdit = false
        private var finished = false

        init(operationID: UUID, processID: pid_t, isCurrent: @escaping @MainActor @Sendable () -> Bool,
             callback: @escaping (SelectedTextConversionOutcome) -> Void) {
            self.operationID = operationID
            self.processID = processID
            self.isCurrent = isCurrent
            self.callback = callback
        }

        func finish(_ outcome: SelectedTextConversionOutcome) {
            guard !finished else { return }
            finished = true
            if attemptedEdit, case .blocked = outcome { callback(.failed) }
            else { callback(outcome) }
        }
    }

    @MainActor private final class SuffixCompletionBox {
        let operationID: UUID
        let callback: (ManualSuffixReplacementOutcome) -> Void
        var attemptedEdit = false
        var evidence: ManualReplacementEvidence?
        private var finished = false

        init(operationID: UUID, callback: @escaping (ManualSuffixReplacementOutcome) -> Void) {
            self.operationID = operationID
            self.callback = callback
        }

        func finish(_ outcome: ManualSuffixReplacementOutcome) {
            guard !finished else { return }
            finished = true
            if attemptedEdit, case .blocked = outcome { callback(.failed) }
            else { callback(outcome) }
        }
    }

    @MainActor private final class CaretCompletionBox {
        let operationID: UUID
        let callback: (CaretWordPreparationOutcome) -> Void
        private var finished = false

        init(operationID: UUID, callback: @escaping (CaretWordPreparationOutcome) -> Void) {
            self.operationID = operationID
            self.callback = callback
        }

        func finish(_ outcome: CaretWordPreparationOutcome) {
            guard !finished else { return }
            finished = true
            callback(outcome)
        }
    }

    private enum SelectionReadResult: @unchecked Sendable {
        case none
        case selected(SelectionSnapshot)
        case fallback(selectionKnown: Bool, identifier: String?, range: CFRange?)
    }

    // Состояние движка перепечатки (буфер нажатий → юникод-вставка)
    private var lastOriginal = ""
    private var lastConverted = ""
    private var lastWasBuffer = false
    private var lastSelectionLocation: Int?
    private(set) var lastTransaction: ConversionTransaction?
    private(set) var lastLearningPair: (original: String, converted: String)?
    private(set) var lastManualTargetLayoutID: String?
    var canReconvert: Bool {
        !isConverting && lastWasBuffer && !lastConverted.isEmpty
    }

    init(focusedElementResolver: NativeFocusedEditableResolver) {
        self.focusedElementResolver = focusedElementResolver
    }

    /// Создаёт CGEventSource с маркером, чтобы KeyboardMonitor игнорировал наши события
    nonisolated private func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = kRuSwitcherEventMarker
        return source
    }

    // MARK: - Public API

    func convertSelectedText(
        requireReadableSelection: Bool = true,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        completion: @escaping (SelectedTextConversionOutcome) -> Void
    ) {
        guard isCurrent() else {
            completion(.blocked(.editorChanged))
            return
        }
        guard let operationID = operations.begin() else {
            completion(.blocked(.busy))
            return
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            operations.finish(operationID)
            completion(.blocked(.fieldUnavailable))
            return
        }
        let processID = frontmost.processIdentifier
        let bundleID = frontmost.bundleIdentifier
        let completion = ManualCompletionBox(operationID: operationID, processID: processID,
            isCurrent: isCurrent, callback: completion)
        if processID == ProcessInfo.processInfo.processIdentifier {
            rslog("manual_self_selection_main_thread")
            let result = readSelection(processID: processID, bundleID: bundleID)
            handleSelectionRead(result, requireReadableSelection: requireReadableSelection, completion: completion)
            return
        }
        manualQueue.async { [weak self] in
            guard let self else { return }
            let result = self.readSelection(processID: processID, bundleID: bundleID)
            Task { @MainActor [weak self] in
                self?.handleSelectionRead(
                    result,
                    requireReadableSelection: requireReadableSelection,
                    completion: completion
                )
            }
        }
    }

    private func selectionRefusal(_ completion: ManualCompletionBox,
                                  checkRange: Bool = false,
                                  expectedText: String? = nil) -> ConversionRefusal? {
        if let reason = basicSelectionRefusal(completion) { return reason }
        guard let identifier = completion.identifier else { return nil }
        let result = focusedElementResolver.withElement(
            processID: completion.processID, expectedIdentifier: identifier,
            timeoutMilliseconds: 50, allowTreeSearch: true
        ) { lease -> ConversionRefusal? in
            guard checkRange, let expected = completion.range else { return nil }
            let read = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
            guard read.0 == .success, let raw = read.1,
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return .fieldUnavailable }
            let value = unsafeDowncast(raw, to: AXValue.self)
            var actual = CFRange()
            guard AXValueGetType(value) == .cfRange,
                  AXValueGetValue(value, .cfRange, &actual) else { return .fieldUnavailable }
            guard actual.location == expected.location && actual.length == expected.length else {
                return .editorChanged
            }
            guard let expectedText else { return nil }
            let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
            guard textRead.0 == .success, let text = textRead.1 as? String else { return .fieldUnavailable }
            return ManualMutationSafety.matchesSelectionText(text, expected: expectedText,
                range: NSRange(location: actual.location, length: actual.length)) ? nil : .editorChanged
        }
        if let reason = basicSelectionRefusal(completion) { return reason }
        switch result {
        case let .value(reason): return reason
        case .unavailable(.identifierMismatch): return .editorChanged
        case .unavailable: return .fieldUnavailable
        }
    }

    private func basicSelectionRefusal(_ completion: ManualCompletionBox) -> ConversionRefusal? {
        guard operations.owns(completion.operationID), completion.isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == completion.processID else {
            return .editorChanged
        }
        return AutoSwitchPolicy.secureInputActive ? .secureInput : nil
    }

    nonisolated private func selectionRefusalBeforeAX(_ completion: ManualCompletionBox) -> ConversionRefusal? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { basicSelectionRefusal(completion) }
        }
        return DispatchQueue.main.sync { basicSelectionRefusal(completion) }
    }

    private func finishSelection(_ outcome: SelectedTextConversionOutcome, completion: ManualCompletionBox) {
        guard operations.owns(completion.operationID) else {
            completion.finish(.blocked(.editorChanged))
            return
        }
        let result: SelectedTextConversionOutcome
        if completion.attemptedEdit, case .blocked = outcome { result = .failed }
        else { result = outcome }
        if result == .failed || result == .postedUnverified {
            clearState()
        }
        operations.finish(completion.operationID)
        completion.finish(result)
    }

    private func finishSuffix(_ outcome: ManualSuffixReplacementOutcome, completion: SuffixCompletionBox) {
        guard operations.finish(completion.operationID) else {
            completion.finish(.blocked(.editorChanged))
            return
        }
        completion.finish(outcome)
    }

    private func finishCaret(_ outcome: CaretWordPreparationOutcome, completion: CaretCompletionBox) {
        completion.finish(operations.finish(completion.operationID) ? outcome : .blocked(.editorChanged))
    }

    /// Replaces the exact text immediately before the caret through AX. Unlike
    /// Backspace + Unicode event posting, this cannot leave a half-deleted word
    /// when an application drops the insertion event.
    ///
    /// Hosts with unreliable AX selection (Ghostty, Codex, terminals) use
    /// targeted Backspace+Unicode instead: setting `kAXSelectedText` without a
    /// real selection inserts and duplicates (`converted` + original).
    func replaceFocusedSuffix(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        targetLayoutID: String? = nil,
        expectedCaretLocation: Int? = nil,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping (ManualSuffixReplacementOutcome) -> Void
    ) {
        guard isCurrent() else {
            completion(.blocked(.editorChanged))
            return
        }
        guard !expected.isEmpty, !replacement.isEmpty else {
            completion(.blocked(.uncertain))
            return
        }
        guard let operationID = operations.begin() else {
            completion(.blocked(.busy))
            return
        }
        let completion = SuffixCompletionBox(operationID: operationID, callback: completion)
        let callerIsCurrent = isCurrent
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.operations.owns(operationID) == true && callerIsCurrent()
        }
        var prefersKeyboardDeletion = ManualHostPolicy.shared.prefersKeyboardDeletion(bundleID: focus.bundleID)
        #if RUSWITCH_TEST_HOST
        prefersKeyboardDeletion = prefersKeyboardDeletion
            || CommandLine.arguments.contains("--force-keyboard-deletion-fallback")
        #endif
        if prefersKeyboardDeletion {
            replaceFocusedSuffixViaKeyboardDeletion(
                expected: expected,
                replacement: replacement,
                focus: focus,
                targetLayoutID: targetLayoutID,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        #if RUSWITCH_TEST_HOST
        if CommandLine.arguments.contains("--force-synthetic-input-fallback") {
            finishFocusedSuffixReplacement(
                .unchanged,
                expected: expected,
                replacement: replacement,
                focus: focus,
                targetLayoutID: targetLayoutID,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        if CommandLine.arguments.contains("--force-ax-unavailable-fallback") {
            finishFocusedSuffixReplacement(
                .notAttempted(.fieldUnavailable),
                expected: expected,
                replacement: replacement,
                focus: focus,
                targetLayoutID: targetLayoutID,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        #endif
        if focus.processID == ProcessInfo.processInfo.processIdentifier {
            let verification = setAndVerifyFocusedSuffix(
                expected: expected,
                replacement: replacement,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
                pollForDelayedCommit: false,
                mutationRefusal: { isCurrent() ? nil : .editorChanged }
            )
            if case .notAttempted = verification {} else { completion.attemptedEdit = true }
            finishFocusedSuffixReplacement(
                verification,
                expected: expected,
                replacement: replacement,
                focus: focus,
                targetLayoutID: targetLayoutID,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        // External hosts: convert the current/previous word by keyboard
        // (Backspace + Unicode), not by an AX `kAXSelectedText` write. Setting
        // that attribute over a *programmatically* created selection inserts
        // instead of replacing in Chromium/Electron (Claude desktop, VS Code)
        // and terminals, leaving the original word and duplicating text. The
        // keystroke path is the same mechanism the automatic converter already
        // uses successfully in those hosts, and it is gated by an AX suffix
        // probe plus the isCurrent()/frontmost recheck before deleting. A real,
        // user-made selection still takes the AX path in `readSelection`.
        replaceFocusedSuffixViaKeyboardDeletion(
            expected: expected,
            replacement: replacement,
            focus: focus,
            targetLayoutID: targetLayoutID,
            expectedCaretLocation: expectedCaretLocation,
            isCurrent: isCurrent,
            completion: completion
        )
    }

    private func finishFocusedSuffixReplacement(
        _ verification: ReplacementVerification,
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        targetLayoutID: String?,
        expectedCaretLocation: Int?,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        guard isCurrent() else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        switch verification {
        case .match:
            finishSuffix(.verified, completion: completion)
        case .unchanged:
            if ManualHostPolicy.shared.prefersKeyboardDeletion(bundleID: focus.bundleID) {
                replaceFocusedSuffixViaKeyboardDeletion(
                    expected: expected,
                    replacement: replacement,
                    focus: focus,
                    targetLayoutID: targetLayoutID,
                    expectedCaretLocation: expectedCaretLocation,
                    isCurrent: isCurrent,
                    completion: completion
                )
            } else {
                replaceFocusedSuffixViaSyntheticInput(
                    expected: expected,
                    replacement: replacement,
                    focus: focus,
                    expectedCaretLocation: expectedCaretLocation,
                    isCurrent: isCurrent,
                    completion: completion
                )
            }
        case .notAttempted(.fieldUnavailable):
            replaceFocusedSuffixViaKeyboardDeletion(
                expected: expected,
                replacement: replacement,
                focus: focus,
                targetLayoutID: targetLayoutID,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
        case .mismatch, .unavailable, .notAttempted:
            finishSuffix(.init(verification: verification), completion: completion)
        }
    }

    /// Keyboard replacement for hosts that cannot select-and-replace through AX.
    /// AX-blind hosts select the exact suffix with Shift+Left, then type physical
    /// keys in the target layout. A dropped insertion leaves a selection instead
    /// of destructively deleting text before the token.
    private func replaceFocusedSuffixViaKeyboardDeletion(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        targetLayoutID: String?,
        expectedCaretLocation: Int?,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID,
              isCurrent() else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        let probe = focusedSuffixProbe(
            expected,
            focus: focus,
            expectedCaretLocation: expectedCaretLocation,
            timeoutMilliseconds: 50
        )
        completion.evidence = probe.evidence
        let delivery: KeyboardEventDelivery
        switch probe.verification {
        case .mismatch:
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        case let .notAttempted(reason):
            finishSuffix(.blocked(reason), completion: completion)
            return
        case .match, .unchanged:
            #if RUSWITCH_TEST_HOST
            delivery = CommandLine.arguments.contains("--force-global-event-stream")
                ? .globalEventStream : .targetedProcess
            #else
            delivery = .targetedProcess
            #endif
        case .unavailable:
            // Some custom editors do not expose AX text but do receive marked
            // HID-stream events. Targeted CGEvents are silently ignored there.
            delivery = .globalEventStream
        }
        // Re-check freshness after the AX probe and before posting any edit.
        // The probe above is itself an AX round-trip (up to 50 ms); when it
        // returns .unavailable there is no content confirmation at all, so
        // this recheck — not AX — is the only thing standing between "safe"
        // and "delete whatever is actually under the caret now".
        guard isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }

        let replacementSpanCount = expected.count
        guard replacementSpanCount > 0 else {
            finishSuffix(.blocked(.uncertain), completion: completion)
            return
        }
        if delivery == .globalEventStream {
            guard let targetLayoutID,
                  let strokes = physicalReplacementStrokes(
                    for: replacement,
                    targetLayoutID: targetLayoutID
                  ),
                  !strokes.isEmpty else {
                finishSuffix(.blocked(.unsupportedLayout), completion: completion)
                return
            }
            let originalLayoutID = LayoutSwitcher.currentLayoutID()
            LayoutSwitcher.switchTo(layoutID: targetLayoutID)
            // Give the target application one run-loop turn to observe the
            // input-source change before posting physical key codes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                self?.waitForPhysicalReplacementLayout(
                    targetLayoutID: targetLayoutID,
                    originalLayoutID: originalLayoutID,
                    replacementSpanCount: replacementSpanCount,
                    replacement: replacement,
                    strokes: strokes,
                    focus: focus,
                    isCurrent: isCurrent,
                    attempt: 0,
                    completion: completion
                )
            }
            return
        }

        // AX-readable hosts keep the established targeted Unicode path.
        guard let plan = EventReplacementPlan(
            replacingSuffix: expected,
            replacementText: replacement
        ) else {
            rslog("manual_keyboard_ambiguous_deletion")
            finishSuffix(.blocked(.protectedText), completion: completion)
            return
        }
        guard post(plan, to: focus.processID, delivery: delivery) else {
            finishSuffix(.blocked(.deliveryFailed), completion: completion)
            return
        }
        completion.attemptedEdit = true
        rslog("manual_keyboard_deletion_posted")
        verifyPostedSuffixReplacement(
            replacement: replacement,
            focus: focus,
            isCurrent: isCurrent,
            completion: completion
        )
    }

    private func waitForPhysicalReplacementLayout(
        targetLayoutID: String,
        originalLayoutID: String,
        replacementSpanCount: Int,
        replacement: String,
        strokes: [PhysicalReplacementStroke],
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        attempt: Int,
        completion: SuffixCompletionBox
    ) {
        guard operations.owns(completion.operationID) else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        guard isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            restoreLayoutAfterAbortedPhysicalReplacement(originalLayoutID)
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        guard LayoutSwitcher.currentLayoutID() == targetLayoutID else {
            guard attempt < 20 else {
                restoreLayoutAfterAbortedPhysicalReplacement(originalLayoutID)
                finishSuffix(.blocked(.unsupportedLayout), completion: completion)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.003) { [weak self] in
                self?.waitForPhysicalReplacementLayout(
                    targetLayoutID: targetLayoutID,
                    originalLayoutID: originalLayoutID,
                    replacementSpanCount: replacementSpanCount,
                    replacement: replacement,
                    strokes: strokes,
                    focus: focus,
                    isCurrent: isCurrent,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
            return
        }
        guard postPhysicalReplacement(
            replacementSpanCount: replacementSpanCount,
            strokes: strokes,
            to: focus.processID
        ) else {
            restoreLayoutAfterAbortedPhysicalReplacement(originalLayoutID)
            finishSuffix(.blocked(.deliveryFailed), completion: completion)
            return
        }
        completion.attemptedEdit = true
        rslog("manual_global_physical_selection_posted")
        verifyPostedSuffixReplacement(
            replacement: replacement,
            focus: focus,
            isCurrent: isCurrent,
            completion: completion
        )
    }

    private func restoreLayoutAfterAbortedPhysicalReplacement(_ layoutID: String) {
        guard !layoutID.isEmpty, LayoutSwitcher.currentLayoutID() != layoutID else { return }
        LayoutSwitcher.switchTo(layoutID: layoutID)
    }

    private func verifyPostedSuffixReplacement(
        replacement: String,
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard isCurrent(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
                self.finishSuffix(.failed, completion: completion)
                return
            }
            let verification = self.readReplacement(
                replacement, evidence: completion.evidence, focus: focus,
                timeoutMilliseconds: 40
            )
            guard isCurrent(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
                self.finishSuffix(.failed, completion: completion)
                return
            }
            self.finishSuffix(.init(verification: verification), completion: completion)
        }
    }

    private func replaceFocusedSuffixViaSyntheticInput(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int?,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID,
              !expected.isEmpty,
              isCurrent() else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        let probe = focusedSuffixProbe(expected, focus: focus,
            expectedCaretLocation: expectedCaretLocation, timeoutMilliseconds: 50)
        guard probe.verification == .match else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        completion.evidence = probe.evidence

        guard isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            finishSuffix(.blocked(.editorChanged), completion: completion)
            return
        }
        completion.attemptedEdit = true
        guard postSelection(characterCount: expected.count, to: focus.processID) else {
            finishSuffix(.failed, completion: completion)
            return
        }
        let selectionDeadline = DispatchTime.now().uptimeNanoseconds + 90_000_000
        waitForSyntheticSelection(
            expected: expected,
            replacement: replacement,
            focus: focus,
            isCurrent: isCurrent,
            deadlineNanoseconds: selectionDeadline,
            completion: completion
        )
    }

    /// Targeted selection events are delivered asynchronously. Polling a few
    /// times avoids a fixed-delay race while preserving the exact-text safety
    /// check: Unicode is never posted unless the intended suffix is selected.
    private func waitForSyntheticSelection(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        deadlineNanoseconds: UInt64,
        completion: SuffixCompletionBox
    ) {
        guard isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            finishSuffix(.failed, completion: completion)
            return
        }
        // Require a real non-empty selection range, not only SelectedText string.
        // Some Electron hosts echo the caret word as "selected" without selecting.
        if selectedRangeAndTextMatch(expected, focus: focus, timeoutMilliseconds: 12) {
            guard isCurrent(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
                finishSuffix(.failed, completion: completion)
                return
            }
            guard postUnicodeText(replacement, to: focus.processID) else {
                finishSuffix(.failed, completion: completion)
                return
            }
            verifyPostedSuffixReplacement(replacement: replacement, focus: focus,
                isCurrent: isCurrent, completion: completion)
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            finishSuffix(.failed, completion: completion)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            self?.waitForSyntheticSelection(
                expected: expected,
                replacement: replacement,
                focus: focus,
                isCurrent: isCurrent,
                deadlineNanoseconds: deadlineNanoseconds,
                completion: completion
            )
        }
    }

    private func handleSelectionRead(
        _ result: SelectionReadResult,
        requireReadableSelection: Bool,
        completion: ManualCompletionBox
    ) {
        switch result {
        case let .selected(snapshot):
            completion.identifier = snapshot.identifier
            completion.range = snapshot.range
        case let .fallback(_, identifier, range):
            completion.identifier = identifier
            completion.range = range
        case .none: break
        }
        if let reason = selectionRefusal(completion) {
            finishSelection(.blocked(reason), completion: completion)
            return
        }
        switch result {
        case .none:
            finishSelection(.none, completion: completion)
        case let .fallback(selectionKnown, _, _):
            finishSelection(requireReadableSelection ? .blocked(.fieldUnavailable)
                : .unreadableSelection(selectionKnown: selectionKnown), completion: completion)
        case let .selected(snapshot):
            guard let conversion = DynamicKeyMapping.convertSelectedText(snapshot.text) else {
                finishSelection(.blocked(.unsupportedLayout), completion: completion)
                return
            }
            var replacement = manualReplacement(
                typed: snapshot.text,
                converted: conversion.converted,
                targetLanguage: conversion.targetLanguage
            )
            var sourceLayoutID = conversion.sourceLayoutID
            var targetLayoutID = conversion.targetLayoutID
            if lastSelectionLocation == snapshot.range.location,
               lastTransaction?.focus.processID == snapshot.processID,
               lastTransaction?.focus.identifier == snapshot.identifier,
               lastConverted == snapshot.text {
                replacement = lastOriginal
                sourceLayoutID = lastTransaction?.targetLayoutID
                targetLayoutID = lastTransaction?.sourceLayoutID
            }
            let preparedReplacement = replacement
            let preparedSourceLayoutID = sourceLayoutID
            let preparedTargetLayoutID = targetLayoutID
            guard sourceLayoutID != nil, targetLayoutID != nil else {
                finishSelection(.blocked(.unsupportedLayout), completion: completion)
                return
            }
            if snapshot.processID == ProcessInfo.processInfo.processIdentifier {
                // AX dispatches an in-process NSTextView mutation directly into AppKit.
                // AppKit requires that mutation on its main queue and traps otherwise.
                finishSelectedTextReplacement(
                    verification: setAndVerifySelectedText(
                        snapshot: snapshot,
                        replacement: replacement,
                        pollForDelayedCommit: false,
                        completion: completion
                    ),
                    snapshot: snapshot,
                    replacement: replacement,
                    sourceLayoutID: sourceLayoutID,
                    targetLayoutID: targetLayoutID,
                    completion: completion
                )
            } else {
                manualQueue.async { [weak self] in
                    guard let self else { return }
                    let verification = self.setAndVerifySelectedText(
                        snapshot: snapshot,
                        replacement: preparedReplacement,
                        pollForDelayedCommit: true,
                        completion: completion
                    )
                    Task { @MainActor [weak self] in
                        self?.finishSelectedTextReplacement(
                            verification: verification,
                            snapshot: snapshot,
                            replacement: preparedReplacement,
                            sourceLayoutID: preparedSourceLayoutID,
                            targetLayoutID: preparedTargetLayoutID,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    nonisolated private func setAndVerifySelectedText(
        snapshot: SelectionSnapshot,
        replacement: String,
        pollForDelayedCommit: Bool,
        completion: ManualCompletionBox
    ) -> ReplacementVerification {
        if let reason = selectionRefusalBeforeAX(completion) { return .notAttempted(reason) }
        switch focusedElementResolver.withElement(
            processID: snapshot.processID,
            expectedIdentifier: snapshot.identifier,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> ReplacementVerification in
                guard selectionMatches(snapshot, lease: lease) else {
                    return .notAttempted(.editorChanged)
                }
                return setAndVerifySelectedText(
                    snapshot: snapshot,
                    replacement: replacement,
                    pollForDelayedCommit: pollForDelayedCommit,
                    lease: lease,
                    mutationRefusal: { self.selectionRefusalBeforeAX(completion) }
                )
            }
        ) {
        case let .value(result):
            return result
        case .unavailable(.identifierMismatch):
            return .notAttempted(.editorChanged)
        case .unavailable:
            return .notAttempted(.fieldUnavailable)
        }
    }

    nonisolated private func setAndVerifySelectedText(
        snapshot: SelectionSnapshot,
        replacement: String,
        pollForDelayedCommit: Bool,
        lease: NativeAXElementLease,
        mutationRefusal: () -> ConversionRefusal?
    ) -> ReplacementVerification {
        return ManualMutationSafety.perform(validation: {
            if let evidence = snapshot.evidence,
               let current = self.documentText(from: lease),
               !current.utf16.elementsEqual(evidence.document.utf16) {
                return .editorChanged
            }
            return nil
        }, refusal: mutationRefusal) {
            let setResult = lease.setAttribute(kAXSelectedTextAttribute as CFString,
                value: replacement as CFString)
            let deadline = Date().addingTimeInterval(pollForDelayedCommit ? 0.25 : 0)
            var verification: ReplacementVerification
            repeat {
                verification = verifyReplacement(replacement, evidence: snapshot.evidence, lease: lease)
                if verification == .match || verification == .mismatch { return verification }
                if setResult != .success || mutationRefusal() != nil { return verification }
                if Date() < deadline { usleep(5_000) }
            } while Date() < deadline
            return verification
        }
    }

    nonisolated private func documentText(from lease: NativeAXElementLease) -> String? {
        let countRead = lease.copyAttribute(kAXNumberOfCharactersAttribute as CFString)
        guard countRead.0 == .success, let count = countRead.1 as? NSNumber else { return nil }
        return ManualReplacementEvidence.readBoundedDocument(characterCount: count.intValue) {
            let read = lease.copyAttribute(kAXValueAttribute as CFString)
            guard read.0 == .success else { return nil }
            return read.1 as? String
        }
    }

    nonisolated private func verifyReplacement(
        _ replacement: String,
        evidence: ManualReplacementEvidence?,
        lease: NativeAXElementLease
    ) -> ReplacementVerification {
        // A selected string or matching prefix cannot prove the original span was removed.
        guard let evidence else { return .unavailable }
        return evidence.verify(documentText(from: lease), replacement: replacement)
    }

    nonisolated private func readReplacement(
        _ replacement: String,
        evidence: ManualReplacementEvidence?,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> ReplacementVerification {
        switch focusedElementResolver.withElement(
            processID: focus.processID, expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds, allowTreeSearch: true,
            operation: { lease in
                self.verifyReplacement(replacement, evidence: evidence, lease: lease)
            }
        ) {
        case let .value(result): return result
        case .unavailable(.identifierMismatch): return .mismatch
        case .unavailable: return .unavailable
        }
    }

    private func finishSelectedTextReplacement(
        verification: ReplacementVerification,
        snapshot: SelectionSnapshot,
        replacement: String,
        sourceLayoutID: String?,
        targetLayoutID: String?,
        completion: ManualCompletionBox
    ) {
        if case .notAttempted = verification {} else { completion.attemptedEdit = true }
        if let reason = selectionRefusal(completion) {
            let outcome: SelectedTextConversionOutcome = completion.attemptedEdit
                ? (reason == .fieldUnavailable ? .postedUnverified : .failed) : .blocked(reason)
            finishSelection(outcome, completion: completion)
            return
        }
        switch verification {
        case .match:
            recordVerifiedSelection(ConversionTransaction(
                original: snapshot.text, replacement: replacement, boundary: .punctuation(""),
                focus: FocusedElementIdentity(processID: snapshot.processID,
                    bundleID: snapshot.bundleID, identifier: snapshot.identifier),
                sourceLayoutID: sourceLayoutID, targetLayoutID: targetLayoutID,
                sequence: 0, automatic: false
            ), selectionLocation: snapshot.range.location)
            finishSelection(.converted, completion: completion)
        case .unchanged:
            convertSelectionViaKeyboardAsync(
                snapshot: snapshot,
                replacement: replacement,
                sourceLayoutID: sourceLayoutID,
                targetLayoutID: targetLayoutID,
                completion: completion
            )
        case .mismatch, .unavailable, .notAttempted:
            finishSelection(.init(verification: verification), completion: completion)
        }
    }

    nonisolated private func readSelection(processID: pid_t, bundleID: String?) -> SelectionReadResult {
        switch focusedElementResolver.withElement(
            processID: processID,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> SelectionReadResult in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
                    return .fallback(selectionKnown: false, identifier: lease.identifier, range: nil)
                }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &range) else {
                    return .fallback(selectionKnown: false, identifier: lease.identifier, range: nil)
                }
                guard range.length > 0 else { return .none }
                let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
                guard textRead.0 == .success,
                      let text = textRead.1 as? String,
                      !text.isEmpty else {
                    return .fallback(selectionKnown: true, identifier: lease.identifier, range: range)
                }
                return .selected(SelectionSnapshot(
                    processID: processID,
                    identifier: lease.identifier,
                    range: range,
                    text: text,
                    document: self.documentText(from: lease),
                    bundleID: bundleID
                ))
            }
        ) {
        case let .value(result):
            return result
        case .unavailable:
            return .fallback(selectionKnown: false, identifier: nil, range: nil)
        }
    }

    nonisolated private func setAndVerifyFocusedSuffix(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int?,
        pollForDelayedCommit: Bool,
        mutationRefusal: () -> ConversionRefusal?
    ) -> ReplacementVerification {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> ReplacementVerification in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return .notAttempted(.fieldUnavailable) }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var caret = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &caret),
                      caret.length == 0 else { return .notAttempted(.editorChanged) }
                if let expectedCaretLocation,
                   caret.location != expectedCaretLocation { return .notAttempted(.editorChanged) }

                let expectedLength = expected.utf16.count
                guard caret.location >= expectedLength else { return .notAttempted(.editorChanged) }
                var suffixRange = CFRange(
                    location: caret.location - expectedLength,
                    length: expectedLength
                )
                guard let suffixRangeValue = AXValueCreate(.cfRange, &suffixRange) else {
                    return .notAttempted(.fieldUnavailable)
                }
                let suffixRead = lease.copyParameterizedAttribute(
                    kAXStringForRangeParameterizedAttribute as CFString,
                    parameter: suffixRangeValue
                )
                guard suffixRead.0 == .success,
                      let actual = suffixRead.1 as? String else { return .notAttempted(.fieldUnavailable) }
                guard actual.precomposedStringWithCanonicalMapping
                        == expected.precomposedStringWithCanonicalMapping else { return .notAttempted(.editorChanged) }

                let document = self.documentText(from: lease)
                if let reason = mutationRefusal() { return .notAttempted(reason) }
                guard lease.setAttribute(
                    kAXSelectedTextRangeAttribute as CFString,
                    value: suffixRangeValue
                ) == .success else { return .unchanged }

                let snapshot = SelectionSnapshot(
                    processID: focus.processID,
                    identifier: lease.identifier,
                    range: suffixRange,
                    text: expected,
                    document: document,
                    bundleID: focus.bundleID
                )
                // Never call kAXSelectedText unless the selection is confirmed.
                // Setting it with an empty/wrong selection inserts and duplicates.
                guard selectionMatches(snapshot, lease: lease) else { return .unchanged }
                let verification = setAndVerifySelectedText(
                    snapshot: snapshot,
                    replacement: replacement,
                    pollForDelayedCommit: pollForDelayedCommit,
                    lease: lease,
                    mutationRefusal: mutationRefusal
                )

                var finalRange = verification == .match
                    ? CFRange(location: suffixRange.location + replacement.utf16.count, length: 0)
                    : caret
                if let finalRangeValue = AXValueCreate(.cfRange, &finalRange), mutationRefusal() == nil {
                    _ = lease.setAttribute(
                        kAXSelectedTextRangeAttribute as CFString,
                        value: finalRangeValue
                    )
                }
                return verification
            }
        ) {
        case let .value(result):
            return result
        case .unavailable(.identifierMismatch):
            return .notAttempted(.editorChanged)
        case .unavailable:
            return .notAttempted(.fieldUnavailable)
        }
    }

    nonisolated private func selectionMatches(
        _ snapshot: SelectionSnapshot,
        lease: NativeAXElementLease
    ) -> Bool {
        let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
        guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return false }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else { return false }
        guard range.location == snapshot.range.location,
              range.length == snapshot.range.length else { return false }
        let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
        guard textRead.0 == .success, let text = textRead.1 as? String else { return false }
        return ManualMutationSafety.matchesSelectionText(text, expected: snapshot.text,
            range: NSRange(location: snapshot.range.location, length: snapshot.range.length))
    }

    nonisolated private func readTextBeforeCaret(
        focus: FocusedElementIdentity,
        maxUTF16Length: Int
    ) -> CaretPrefixRead {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> CaretPrefixRead in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return .blocked(.fieldUnavailable) }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var caret = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &caret),
                      caret.location >= 0 else { return .blocked(.fieldUnavailable) }
                guard caret.length == 0 else { return .blocked(.editorChanged) }
                if caret.location == 0 {
                    return .value(CaretPrefix(text: "", beginsAtDocumentStart: true,
                        elementIdentifier: lease.identifier, caretLocation: 0))
                }
                let length = min(max(1, maxUTF16Length), caret.location)
                var prefixRange = CFRange(location: caret.location - length, length: length)
                guard let prefixValue = AXValueCreate(.cfRange, &prefixRange) else { return .blocked(.fieldUnavailable) }
                let textRead = lease.copyParameterizedAttribute(
                    kAXStringForRangeParameterizedAttribute as CFString,
                    parameter: prefixValue
                )
                guard textRead.0 == .success, let text = textRead.1 as? String,
                      text.utf16.count == length else { return .blocked(.fieldUnavailable) }
                return .value(CaretPrefix(
                    text: text,
                    beginsAtDocumentStart: prefixRange.location == 0,
                    elementIdentifier: lease.identifier,
                    caretLocation: caret.location
                ))
            }
        ) {
        case let .value(text):
            return text
        case .unavailable(.identifierMismatch):
            return .blocked(.editorChanged)
        case .unavailable:
            return .blocked(.fieldUnavailable)
        }
    }

    nonisolated private func focusedSuffixProbe(
        _ expected: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int? = nil,
        timeoutMilliseconds: Int
    ) -> (verification: ReplacementVerification, evidence: ManualReplacementEvidence?) {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: true,
            operation: { lease -> (ReplacementVerification, ManualReplacementEvidence?) in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return (.unavailable, nil) }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var caret = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &caret),
                      caret.length == 0 else { return (.mismatch, nil) }
                if let expectedCaretLocation,
                   caret.location != expectedCaretLocation { return (.mismatch, nil) }
                let expectedLength = expected.utf16.count
                guard caret.location >= expectedLength else { return (.mismatch, nil) }
                var suffixRange = CFRange(
                    location: caret.location - expectedLength,
                    length: expectedLength
                )
                guard let suffixRangeValue = AXValueCreate(.cfRange, &suffixRange) else {
                    return (.unavailable, nil)
                }
                let suffixRead = lease.copyParameterizedAttribute(
                    kAXStringForRangeParameterizedAttribute as CFString,
                    parameter: suffixRangeValue
                )
                guard suffixRead.0 == .success, let actual = suffixRead.1 as? String else {
                    return (.unavailable, nil)
                }
                guard actual.utf16.elementsEqual(expected.utf16) else { return (.mismatch, nil) }
                return (.match, ManualReplacementEvidence(document: self.documentText(from: lease),
                    original: expected, range: NSRange(location: suffixRange.location, length: suffixRange.length)))
            }
        ) {
        case let .value(result):
            return result
        case .unavailable(.identifierMismatch):
            return (.mismatch, nil)
        case .unavailable:
            return (.unavailable, nil)
        }
    }

    nonisolated private func focusedSuffixMatches(
        _ expected: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int? = nil,
        timeoutMilliseconds: Int
    ) -> Bool {
        focusedSuffixProbe(
            expected,
            focus: focus,
            expectedCaretLocation: expectedCaretLocation,
            timeoutMilliseconds: timeoutMilliseconds
        ).verification == .match
    }

    nonisolated private func selectedTextMatches(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> Bool {
        selectedRangeAndTextMatch(expected, focus: focus, timeoutMilliseconds: timeoutMilliseconds)
    }

    /// True only when AX reports a selection whose length and text both match.
    nonisolated private func selectedRangeAndTextMatch(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> Bool {
        let expectedLength = expected.utf16.count
        guard expectedLength > 0 else { return false }
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: true,
            operation: { lease in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return false }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &range),
                      range.length == expectedLength else { return false }
                let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
                guard textRead.0 == .success, let text = textRead.1 as? String else { return false }
                return text.precomposedStringWithCanonicalMapping
                    == expected.precomposedStringWithCanonicalMapping
            }
        ) {
        case let .value(matched):
            return matched
        case .unavailable:
            return false
        }
    }

    func prepareBufferedConversion(keys: [TypedKey]) -> BufferedManualConversion? {
        guard let pair = DynamicKeyMapping.convertKeys(keys) else { return nil }
        let replacement = manualReplacement(
            typed: pair.original,
            converted: pair.converted,
            sourceLayoutID: keys.first?.sourceLayoutID
        )
        return BufferedManualConversion(
            original: pair.original,
            replacement: replacement,
            sourceLayoutID: keys.first?.sourceLayoutID
        )
    }

    func recordPostedManualBuffer(
        _ conversion: BufferedManualConversion,
        transaction: ConversionTransaction
    ) {
        lastSelectionLocation = nil
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastLearningPair = (conversion.original, conversion.replacement)
        lastWasBuffer = true
        lastTransaction = transaction
    }

    nonisolated private func postSelection(characterCount: Int, to processID: Int32) -> Bool {
        guard characterCount > 0, let source = makeSource() else { return false }
        guard let shiftDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: KC.leftShift,
            keyDown: true
        ) else { return false }
        shiftDown.flags = .maskShift
        shiftDown.postToPid(pid_t(processID))
        for _ in 0..<characterCount {
            guard let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: KC.left,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: KC.left,
                keyDown: false
            ) else { return false }
            down.flags = .maskShift
            up.flags = .maskShift
            down.postToPid(pid_t(processID))
            up.postToPid(pid_t(processID))
        }
        guard let shiftUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: KC.leftShift,
            keyDown: false
        ) else { return false }
        shiftUp.flags = []
        shiftUp.postToPid(pid_t(processID))
        return true
    }

    nonisolated private func postUnicodeText(
        _ text: String,
        to processID: Int32,
        delivery: KeyboardEventDelivery = .targetedProcess
    ) -> Bool {
        guard let source = makeSource(),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
              ) else { return false }
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return false }
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        deliver(down, to: processID, via: delivery)
        deliver(up, to: processID, via: delivery)
        return true
    }

    private func physicalReplacementStrokes(
        for text: String,
        targetLayoutID: String
    ) -> [PhysicalReplacementStroke]? {
        guard !text.isEmpty,
              let layout = LayoutSwitcher.installedLayouts().first(where: {
                LayoutSwitcher.sourceID($0) == targetLayoutID
              }) else { return nil }
        var strokes: [PhysicalReplacementStroke] = []
        for character in text {
            switch character {
            case " ":
                strokes.append(PhysicalReplacementStroke(keyCode: KC.space, shift: false))
            case "\t":
                strokes.append(PhysicalReplacementStroke(keyCode: KC.tab, shift: false))
            case "\n":
                strokes.append(PhysicalReplacementStroke(keyCode: KC.enter, shift: false))
            default:
                guard let physicalKeys = DynamicKeyMapping.physicalKeys(
                    for: character,
                    layout: layout
                ) else { return nil }
                strokes.append(contentsOf: physicalKeys.map {
                    PhysicalReplacementStroke(keyCode: $0.keyCode, shift: $0.shift)
                })
            }
        }
        return strokes
    }

    private func postPhysicalReplacement(
        replacementSpanCount: Int,
        strokes: [PhysicalReplacementStroke],
        to processID: Int32
    ) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              var events = selectionEvents(count: replacementSpanCount) else { return false }
        events.reserveCapacity(events.count + strokes.count * 2)
        for stroke in strokes {
            guard let source = makeSource(),
                  let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: true
                  ),
                  let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: false
                  ) else { return false }
            let flags: CGEventFlags = stroke.shift ? .maskShift : []
            down.flags = flags
            up.flags = flags
            events.append(down)
            events.append(up)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            return false
        }
        for event in events {
            deliver(event, to: processID, via: .globalEventStream)
        }
        return true
    }

    nonisolated private func selectionEvents(count: Int) -> [CGEvent]? {
        guard count > 0 else { return nil }
        var events: [CGEvent] = []
        events.reserveCapacity(count * 2)
        for _ in 0..<count {
            guard let source = makeSource(),
                  let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: KC.left,
                    keyDown: true
                  ),
                  let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: KC.left,
                    keyDown: false
                  ) else { return nil }
            down.flags = .maskShift
            up.flags = .maskShift
            events.append(down)
            events.append(up)
        }
        return events
    }

    /// Global delivery is used only after AX explicitly reports that the text
    /// surface is unavailable. The source marker keeps our own event tap from
    /// treating this replacement as fresh user typing.
    nonisolated private func deliver(
        _ event: CGEvent,
        to processID: Int32,
        via delivery: KeyboardEventDelivery
    ) {
        switch delivery {
        case .targetedProcess:
            event.postToPid(pid_t(processID))
        case .globalEventStream:
            event.post(tap: .cghidEventTap)
        }
    }

    func recordCommittedTransaction(_ transaction: ConversionTransaction) {
        lastSelectionLocation = nil
        lastTransaction = transaction
        lastLearningPair = (transaction.original, transaction.replacement)
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastWasBuffer = true
    }

    func recordVerifiedSelection(_ transaction: ConversionTransaction, selectionLocation: Int) {
        recordCommittedTransaction(transaction)
        lastSelectionLocation = selectionLocation
        lastManualTargetLayoutID = transaction.targetLayoutID
    }

    /// Recovers the last token after focus/navigation cleared the physical-key
    /// buffer. AX work stays off the main/event-tap thread; replacement still
    /// performs a fresh identity and exact-suffix check.
    func prepareCaretWordConversion(
        focus: FocusedElementIdentity,
        completion: @escaping (CaretWordPreparationOutcome) -> Void
    ) {
        guard let operationID = operations.begin() else {
            completion(.busy)
            return
        }
        let completion = CaretCompletionBox(operationID: operationID, callback: completion)
        if focus.processID == ProcessInfo.processInfo.processIdentifier {
            finishCaretPreparation(readTextBeforeCaret(focus: focus, maxUTF16Length: 96),
                focus: focus, completion: completion)
            return
        }
        manualQueue.async { [weak self] in
            guard let self else { return }
            let prefix = self.readTextBeforeCaret(focus: focus, maxUTF16Length: 96)
            Task { @MainActor [weak self] in
                self?.finishCaretPreparation(prefix, focus: focus, completion: completion)
            }
        }
    }

    private func finishCaretPreparation(_ read: CaretPrefixRead, focus: FocusedElementIdentity,
                                        completion: CaretCompletionBox) {
        guard operations.owns(completion.operationID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            finishCaret(.blocked(.editorChanged), completion: completion)
            return
        }
        let prefix: CaretPrefix
        switch read {
        case let .blocked(reason):
            finishCaret(.blocked(reason), completion: completion)
            return
        case let .value(value): prefix = value
        }
        switch focusedElementResolver.resolve(processID: focus.processID,
            expectedIdentifier: prefix.elementIdentifier, timeoutMilliseconds: 50, allowTreeSearch: true) {
        case .unavailable(.identifierMismatch):
            finishCaret(.blocked(.editorChanged), completion: completion)
            return
        case .unavailable:
            finishCaret(.blocked(.fieldUnavailable), completion: completion)
            return
        case .resolved: break
        }
        guard let parsed = CaretTokenParser.tokenBeforeCaret(from: prefix.text,
            tokenAtInputStartIsComplete: prefix.beginsAtDocumentStart) else {
            let body = prefix.text.trimmingCharacters(in: .whitespaces)
            let truncatedToken = !prefix.beginsAtDocumentStart
                && !body.contains(where: \.isWhitespace) && body.contains(where: \.isLetter)
            finishCaret(truncatedToken ? .blocked(.uncertain) : .noCandidate, completion: completion)
            return
        }
        guard let conversion = DynamicKeyMapping.convertSelectedText(parsed.word),
              conversion.sourceLayoutID != nil, conversion.targetLayoutID != nil else {
            finishCaret(.blocked(.unsupportedLayout), completion: completion)
            return
        }
        let replacement = manualReplacement(typed: parsed.word, converted: conversion.converted,
            targetLanguage: conversion.targetLanguage)
        guard replacement != parsed.word else {
            finishCaret(.noCandidate, completion: completion)
            return
        }
        finishCaret(.conversion(CaretWordConversion(
            original: parsed.word, replacement: replacement,
            expectedSuffix: parsed.word + parsed.trailingWhitespace,
            elementIdentifier: prefix.elementIdentifier, caretLocation: prefix.caretLocation,
            sourceLayoutID: conversion.sourceLayoutID, targetLayoutID: conversion.targetLayoutID
        )), completion: completion)
    }

    func recordPostedCaretWord(
        _ conversion: CaretWordConversion,
        transaction: ConversionTransaction
    ) {
        lastSelectionLocation = nil
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastLearningPair = (conversion.original, conversion.replacement)
        lastWasBuffer = true
        lastTransaction = transaction
        lastManualTargetLayoutID = conversion.targetLayoutID
    }

    /// Builds the next forced toggle without mutating the remembered pair.
    /// The caller commits it only after the targeted replacement was posted.
    func prepareReconversion(trailingSpaces: Int = 0) -> BufferedManualReconversion? {
        guard canReconvert else { return nil }
        if let location = lastSelectionLocation {
            let spaces = String(repeating: " ", count: max(0, trailingSpaces))
            return BufferedManualReconversion(
                current: lastConverted + spaces, replacement: lastOriginal + spaces,
                targetLayoutID: lastTransaction?.sourceLayoutID,
                focus: lastTransaction?.focus,
                expectedCaretLocation: location + lastConverted.utf16.count + spaces.utf16.count
            )
        }
        // Do not set isConverting here — only once replaceFocusedSuffix actually
        // starts, otherwise a failed stage leaves canReconvert permanently false.
        let currentBody = lastConverted.trimmingCharacters(in: .whitespaces)
        let replacementBody = lastOriginal.trimmingCharacters(in: .whitespaces)
        guard !currentBody.isEmpty, !replacementBody.isEmpty else { return nil }

        // Match the word body first. Trailing spaces after auto-convert are
        // unreliable across editors (consumed vs replayed Space), and requiring
        // them caused reconversion to always mismatch and no-op.
        let spaceCount: Int
        if trailingSpaces > 0 {
            spaceCount = trailingSpaces
        } else if let transaction = lastTransaction,
                  case let .space(count) = transaction.boundary {
            spaceCount = max(1, count)
        } else if lastConverted.hasSuffix(" ") || lastOriginal.hasSuffix(" ") {
            spaceCount = 1
        } else {
            spaceCount = 0
        }
        let spaces = String(repeating: " ", count: spaceCount)
        return BufferedManualReconversion(
            current: currentBody + spaces,
            replacement: replacementBody + spaces,
            targetLayoutID: lastTransaction?.sourceLayoutID
        )
    }

    func recordPostedReconversion(
        _ reconversion: BufferedManualReconversion,
        transaction: ConversionTransaction
    ) {
        lastOriginal = reconversion.current
        lastConverted = reconversion.replacement
        if lastSelectionLocation != nil, let previous = lastTransaction {
            lastTransaction = ConversionTransaction(
                original: reconversion.current, replacement: reconversion.replacement,
                boundary: .punctuation(""), focus: previous.focus,
                sourceLayoutID: previous.targetLayoutID, targetLayoutID: previous.sourceLayoutID,
                sequence: transaction.sequence, editRevision: transaction.editRevision, automatic: false
            )
        } else {
            lastTransaction = transaction
        }
        lastWasBuffer = true
    }

    func cancelPendingReconversion() {
        operations.cancel()
    }

    func discardTransactionIfCurrent(_ transaction: ConversionTransaction) {
        guard lastTransaction?.executionIdentity == transaction.executionIdentity else { return }
        clearState()
    }

    func clearState() {
        operations.cancel()
        lastOriginal = ""
        lastConverted = ""
        lastWasBuffer = false
        lastSelectionLocation = nil
        lastTransaction = nil
        lastLearningPair = nil
        lastManualTargetLayoutID = nil
    }

    // MARK: - Private

    private func manualReplacement(typed: String, converted: String, sourceLayoutID: String?) -> String {
        let langs = sourceLayoutID.flatMap(LayoutSwitcher.languagePair(sourceLayoutID:))
            ?? LayoutSwitcher.currentAndOppositeLanguage()
        guard let targetLanguage = langs?.opposite else { return converted }
        return manualReplacement(typed: typed, converted: converted, targetLanguage: targetLanguage)
    }

    private func manualReplacement(typed: String, converted: String, targetLanguage: String) -> String {
        return AutoConvertCandidateGenerator.bestCandidate(
            typed: typed,
            converted: converted,
            targetLanguage: targetLanguage,
            isValidWord: { word, language in
                !word.isEmpty && Dict.isAvailable(language) && Dict.isValidWord(word, lang: language)
            }
        )?.replacement ?? converted
    }

    private func convertSelectionViaKeyboardAsync(
        snapshot: SelectionSnapshot,
        replacement: String,
        sourceLayoutID: String?,
        targetLayoutID: String?,
        completion: ManualCompletionBox
    ) {
        guard sourceLayoutID != nil, targetLayoutID != nil else {
            finishSelection(.blocked(.unsupportedLayout), completion: completion)
            return
        }
        if let reason = selectionRefusal(completion, checkRange: true, expectedText: snapshot.text) {
            finishSelection(.blocked(reason), completion: completion)
            return
        }
        // AX left the original selection intact. Typing over that exact span
        // needs neither deletion events nor access to the user's pasteboard.
        guard postUnicodeText(replacement, to: snapshot.processID) else {
            finishSelection(.blocked(.deliveryFailed), completion: completion)
            return
        }
        completion.attemptedEdit = true
        pollSelectedTextReadback(snapshot: snapshot, replacement: replacement,
            sourceLayoutID: sourceLayoutID, targetLayoutID: targetLayoutID,
            deadline: DispatchTime.now().uptimeNanoseconds + 150_000_000, completion: completion)
    }

    private func pollSelectedTextReadback(
        snapshot: SelectionSnapshot, replacement: String,
        sourceLayoutID: String?, targetLayoutID: String?,
        deadline: UInt64, completion: ManualCompletionBox
    ) {
        if let reason = basicSelectionRefusal(completion) {
            finishSelection(.blocked(reason), completion: completion)
            return
        }
        guard Self.selectedReadbackTimeoutMilliseconds(deadline: deadline,
            now: DispatchTime.now().uptimeNanoseconds) != nil else {
            finishSelectedTextReadback(.unavailable, snapshot: snapshot, replacement: replacement,
                sourceLayoutID: sourceLayoutID, targetLayoutID: targetLayoutID, completion: completion)
            return
        }
        let receive: @MainActor @Sendable (ReplacementVerification) -> Void = { [weak self] verification in
            guard let self else { return }
            if (verification == .unchanged || verification == .unavailable),
               DispatchTime.now().uptimeNanoseconds < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.pollSelectedTextReadback(snapshot: snapshot, replacement: replacement,
                        sourceLayoutID: sourceLayoutID, targetLayoutID: targetLayoutID,
                        deadline: deadline, completion: completion)
                }
                return
            }
            self.finishSelectedTextReadback(verification, snapshot: snapshot,
                replacement: replacement, sourceLayoutID: sourceLayoutID,
                targetLayoutID: targetLayoutID, completion: completion)
        }
        if snapshot.processID == ProcessInfo.processInfo.processIdentifier {
            receive(readSelectedTextReplacement(snapshot: snapshot, replacement: replacement, deadline: deadline))
        } else {
            manualQueue.async { [weak self] in
                guard let self else { return }
                let verification = self.readSelectedTextReplacement(snapshot: snapshot, replacement: replacement,
                    deadline: deadline)
                Task { @MainActor in receive(verification) }
            }
        }
    }

    nonisolated static func selectedReadbackTimeoutMilliseconds(deadline: UInt64, now: UInt64) -> Int? {
        guard now < deadline else { return nil }
        let remaining = (deadline - now) / 1_000_000
        return remaining > 0 ? Int(min(remaining, 150)) : nil
    }

    nonisolated private func readSelectedTextReplacement(snapshot: SelectionSnapshot,
                                                      replacement: String, deadline: UInt64) -> ReplacementVerification {
        // Recompute after queueing: a retry must not acquire a fresh AX budget.
        guard let timeout = Self.selectedReadbackTimeoutMilliseconds(deadline: deadline,
            now: DispatchTime.now().uptimeNanoseconds) else { return .unavailable }
        switch focusedElementResolver.withElement(
            processID: snapshot.processID, expectedIdentifier: snapshot.identifier,
            timeoutMilliseconds: timeout, allowTreeSearch: true,
            operation: { lease in
                self.verifyReplacement(replacement, evidence: snapshot.evidence, lease: lease)
            }
        ) {
        case let .value(result):
            if result == .match, DispatchTime.now().uptimeNanoseconds >= deadline { return .unavailable }
            return result
        case .unavailable(.identifierMismatch): return .mismatch
        case .unavailable: return .unavailable
        }
    }

    private func finishSelectedTextReadback(_ verification: ReplacementVerification,
                                         snapshot: SelectionSnapshot, replacement: String,
                                         sourceLayoutID: String?, targetLayoutID: String?,
                                         completion: ManualCompletionBox) {
        guard operations.owns(completion.operationID) else {
            finishSelection(.blocked(.editorChanged), completion: completion)
            return
        }
        if let reason = selectionRefusal(completion) {
            finishSelection(reason == .fieldUnavailable ? .postedUnverified : .failed, completion: completion)
            return
        }
        if verification == .match {
            recordVerifiedSelection(ConversionTransaction(
                original: snapshot.text, replacement: replacement, boundary: .punctuation(""),
                focus: FocusedElementIdentity(processID: snapshot.processID,
                    bundleID: snapshot.bundleID, identifier: snapshot.identifier),
                sourceLayoutID: sourceLayoutID, targetLayoutID: targetLayoutID,
                sequence: 0, automatic: false
            ), selectionLocation: snapshot.range.location)
        }
        finishSelection(.init(verification: verification), completion: completion)
    }
}

extension TextConverter: KeyboardEventPosting {
    func post(
        _ plan: EventReplacementPlan,
        to processID: Int32,
        delivery: KeyboardEventDelivery
    ) -> Bool {
        if delivery == .globalEventStream,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != processID {
            return false
        }
        CallbackPhaseProbe.mark("post.start")
        defer { CallbackPhaseProbe.mark("post.end") }
        guard let events = NativeKeyboardEventBatch.build(plan, marker: kRuSwitcherEventMarker) else { return false }
        for event in events {
            deliver(event, to: processID, via: delivery)
        }
        return true
    }
}
