import AppKit
import ApplicationServices
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

/// Read-only AX safety probe. It never changes the selected range or value.
/// A strict deadline prevents a slow application from starving the event tap.
final class FocusedTextContextReader: FocusedTextContextReading, @unchecked Sendable {
    private static let timeoutCooldown: TimeInterval = 1

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TextContextPreflight?

        func set(_ newValue: TextContextPreflight) {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }

        func get() -> TextContextPreflight? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        let callback: @MainActor (TextContextValidation) -> Void

        init(_ callback: @escaping @MainActor (TextContextValidation) -> Void) {
            self.callback = callback
        }
    }

    private let validationQueue = DispatchQueue(
        label: "com.ruswitcher.ax-validation",
        qos: .userInteractive
    )
    private let verificationQueue = DispatchQueue(
        label: "com.ruswitcher.ax-verification",
        qos: .userInitiated
    )
    private let focusedElementResolver: NativeFocusedEditableResolver
    private var disabledUntil: [String: Date] = [:]

    init(focusedElementResolver: NativeFocusedEditableResolver) {
        self.focusedElementResolver = focusedElementResolver
    }

    @MainActor
    func validate(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int = 4
    ) -> TextContextPreflight {
        guard !expectedSuffix.isEmpty else { return .unavailable }
        let effectiveDeadline = min(
            ReplacementTiming.preflightDeadlineMilliseconds,
            max(1, deadlineMilliseconds)
        )
        let deadline = DispatchTime.now() + .milliseconds(effectiveDeadline)
        if focus.processID == ProcessInfo.processInfo.processIdentifier {
            return readLocalAnchor(
                expectedSuffix: expectedSuffix,
                focus: focus,
                timeoutMilliseconds: effectiveDeadline
            )
        }
        let key = Self.focusKey(focus)
        let isWarm = focusedElementResolver.cachedIdentifier(processID: focus.processID) != nil
        if let until = disabledUntil[key] {
            // A warm cache is allowed to retry immediately: Ghostty-class apps
            // often timeout once and then answer from the warmed element.
            if until > Date(), !isWarm {
                return .unavailable
            }
            disabledUntil.removeValue(forKey: key)
        }

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        validationQueue.async { [self] in
            defer { semaphore.signal() }
            let remaining = Self.remainingMilliseconds(until: deadline)
            guard remaining > 0 else {
                box.set(.unavailable)
                return
            }
            let first = readAnchor(
                expectedSuffix: expectedSuffix,
                focus: focus,
                timeoutMilliseconds: max(1, remaining - 1)
            )
            if case .value(.mismatch) = first,
               Self.remainingMilliseconds(until: deadline) > 1 {
                box.set(.mismatch)
                // Short tokens can reach the boundary before WebKit/Electron has
                // published the last character through AX. Retry once inside the
                // existing deadline; a real cursor/focus mismatch remains blocked.
                usleep(750)
                let retryRemaining = Self.remainingMilliseconds(until: deadline)
                guard retryRemaining > 0 else {
                    box.set(.mismatch)
                    return
                }
                let retry = preflightResult(readAnchor(
                    expectedSuffix: expectedSuffix,
                    focus: focus,
                    timeoutMilliseconds: retryRemaining
                ))
                // A failed retry must not turn observed disagreement into an
                // AX-unavailable result that permits the explicit AX-less path.
                if case .unavailable = retry {
                    box.set(.mismatch)
                } else {
                    box.set(retry)
                }
            } else {
                box.set(preflightResult(first))
            }
        }
        guard semaphore.wait(timeout: deadline) == .success, let result = box.get() else {
            disabledUntil[key] = Date().addingTimeInterval(Self.timeoutCooldown)
            rslog("ax_probe_timeout")
            if case .mismatch? = box.get() { return .mismatch }
            return .unavailable
        }
        if case .matched = result {
            disabledUntil.removeValue(forKey: key)
        }
        return result
    }

    @MainActor
    private func readLocalAnchor(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> TextContextPreflight {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .unavailable }
        return preflightResult(focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: false,
            operation: { lease in
                guard NSApp.keyWindow?.firstResponder === editor else { return .mismatch }
                let selection = editor.selectedRange()
                guard let range = Self.captureRange(
                    expectedSuffix: expectedSuffix,
                    selection: selection
                ) else { return .mismatch }
                guard let text = localText(in: range, editor: editor) else { return .unavailable }
                return TextReplacementAnchor.capture(
                    expectedSuffix: expectedSuffix,
                    focus: Self.resolvedFocus(focus, lease: lease),
                    selection: selection,
                    capturedRange: range,
                    capturedText: text
                )
            }
        ))
    }

    @MainActor
    func verify(
        expectedSuffix: String,
        anchor: TextReplacementAnchor,
        deadlineMilliseconds: Int,
        completion: @escaping @MainActor (TextContextValidation) -> Void
    ) {
        let callback = CallbackBox(completion)
        let duration = min(
            ReplacementTiming.postedEventVerificationDeadlineMilliseconds,
            max(1, deadlineMilliseconds)
        )
        let deadline = DispatchTime.now() + .milliseconds(duration)
        guard anchor.focus.identifier != nil else {
            DispatchQueue.main.async { callback.callback(.unavailable) }
            return
        }
        if anchor.focus.processID == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { [self] in
                pollLocalVerification(
                    replacement: expectedSuffix,
                    anchor: anchor,
                    deadline: deadline,
                    previousResult: .unavailable,
                    callback: callback
                )
            }
            return
        }
        verificationQueue.async { [self] in
            var result: TextContextValidation = .unavailable
            while Self.remainingMilliseconds(until: deadline) > 0 {
                let remaining = Self.remainingMilliseconds(until: deadline)
                guard remaining > 0 else { break }
                let operation = readAndVerify(
                    replacement: expectedSuffix,
                    anchor: anchor,
                    timeoutMilliseconds: min(4, remaining)
                )
                result = verificationResult(operation)
                if case .unavailable(.identifierMismatch) = operation { break }
                if result == .match { break }
                if Self.remainingMilliseconds(until: deadline) > 1 { usleep(1_000) }
            }
            let finalResult = result
            DispatchQueue.main.async { callback.callback(finalResult) }
        }
    }

    @MainActor
    private func pollLocalVerification(
        replacement: String,
        anchor: TextReplacementAnchor,
        deadline: DispatchTime,
        previousResult: TextContextValidation,
        callback: CallbackBox
    ) {
        let remaining = Self.remainingMilliseconds(until: deadline)
        guard remaining > 0 else {
            callback.callback(previousResult)
            return
        }
        let operation = readLocalVerification(
            replacement: replacement,
            anchor: anchor,
            timeoutMilliseconds: min(4, remaining)
        )
        let result = verificationResult(operation)
        if case .unavailable(.identifierMismatch) = operation {
            callback.callback(.mismatch)
            return
        }
        guard result != .match, Self.remainingMilliseconds(until: deadline) > 0 else {
            callback.callback(result)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
            pollLocalVerification(
                replacement: replacement,
                anchor: anchor,
                deadline: deadline,
                previousResult: result,
                callback: callback
            )
        }
    }

    @MainActor
    private func readLocalVerification(
        replacement: String,
        anchor: TextReplacementAnchor,
        timeoutMilliseconds: Int
    ) -> NativeFocusedElementOperation<TextContextValidation> {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return .unavailable(.identifierMismatch)
        }
        return focusedElementResolver.withElement(
            processID: anchor.focus.processID,
            expectedIdentifier: anchor.focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: false,
            operation: { lease in
                guard NSApp.keyWindow?.firstResponder === editor else { return .mismatch }
                let selection = editor.selectedRange()
                guard let expectedSelection = anchor.expectedSelection(replacement: replacement),
                      selection == expectedSelection,
                      let range = anchor.expectedRange(replacement: replacement) else { return .mismatch }
                guard let text = localText(in: range, editor: editor) else { return .unavailable }
                return anchor.verify(
                    replacement: replacement,
                    focus: Self.resolvedFocus(anchor.focus, lease: lease),
                    selection: selection,
                    capturedRange: range,
                    capturedText: text
                )
            }
        )
    }

    @MainActor
    private func localText(in range: NSRange, editor: NSTextView) -> String? {
        let text = editor.string as NSString
        guard range.location >= 0, range.location != NSNotFound,
              range.length >= 0, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }

    private func readAnchor(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> NativeFocusedElementOperation<TextContextPreflight> {
        focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: false,
            operation: { lease in
                guard let selection = readSelection(lease: lease) else { return .unavailable }
                guard let range = Self.captureRange(
                    expectedSuffix: expectedSuffix,
                    selection: selection
                ) else { return .mismatch }
                guard let text = readText(in: range, lease: lease) else { return .unavailable }
                return TextReplacementAnchor.capture(
                    expectedSuffix: expectedSuffix,
                    focus: Self.resolvedFocus(focus, lease: lease),
                    selection: selection,
                    capturedRange: range,
                    capturedText: text
                )
            }
        )
    }

    private func readAndVerify(
        replacement: String,
        anchor: TextReplacementAnchor,
        timeoutMilliseconds: Int
    ) -> NativeFocusedElementOperation<TextContextValidation> {
        focusedElementResolver.withElement(
            processID: anchor.focus.processID,
            expectedIdentifier: anchor.focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: false,
            operation: { lease in
                guard let selection = readSelection(lease: lease) else { return .unavailable }
                guard let expectedSelection = anchor.expectedSelection(replacement: replacement),
                      selection == expectedSelection,
                      let range = anchor.expectedRange(replacement: replacement) else { return .mismatch }
                guard let text = readText(in: range, lease: lease) else { return .unavailable }
                return anchor.verify(
                    replacement: replacement,
                    focus: Self.resolvedFocus(anchor.focus, lease: lease),
                    selection: selection,
                    capturedRange: range,
                    capturedText: text
                )
            }
        )
    }

    private func preflightResult(
        _ operation: NativeFocusedElementOperation<TextContextPreflight>
    ) -> TextContextPreflight {
        switch operation {
        case let .value(result):
            return result
        case let .unavailable(failure):
            logLookupFailure(failure)
            return failure == .identifierMismatch ? .mismatch : .unavailable
        }
    }

    private func verificationResult(
        _ operation: NativeFocusedElementOperation<TextContextValidation>
    ) -> TextContextValidation {
        switch operation {
        case let .value(result):
            return result
        case let .unavailable(failure):
            logLookupFailure(failure)
            return failure == .identifierMismatch ? .mismatch : .unavailable
        }
    }

    private func readSelection(lease: NativeAXElementLease) -> NSRange? {
        let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
        guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            if rangeRead.0 == .cannotComplete {
                rslog("ax_timeout")
            } else {
                rslog("ax_no_range")
            }
            return nil
        }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var caret = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &caret),
              caret.location >= 0, caret.location != NSNotFound,
              caret.length >= 0, caret.length <= Int.max - caret.location else {
            rslog("ax_range_invalid")
            return nil
        }
        return NSRange(location: caret.location, length: caret.length)
    }

    private static func captureRange(expectedSuffix: String, selection: NSRange) -> NSRange? {
        let expectedLength = expectedSuffix.utf16.count
        guard expectedLength > 0, selection.length == 0,
              selection.location != NSNotFound, selection.location >= expectedLength else { return nil }
        let suffixStart = selection.location - expectedLength
        let prefixLength = min(suffixStart, TextReplacementAnchor.maximumPrefixUTF16Length)
        let start = suffixStart - prefixLength
        return NSRange(location: start, length: selection.location - start)
    }

    private func readText(in range: NSRange, lease: NativeAXElementLease) -> String? {
        guard range.location >= 0, range.location != NSNotFound,
              range.length >= 0, range.length <= Int.max - range.location else { return nil }
        var capturedRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &capturedRange) else { return nil }
        let textRead = lease.copyParameterizedAttribute(
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter: rangeValue
        )
        guard textRead.0 == .success, let raw = textRead.1,
              CFGetTypeID(raw) == CFStringGetTypeID(), let text = raw as? String else {
            if textRead.0 == .cannotComplete {
                rslog("ax_timeout")
            } else {
                rslog("ax_no_string_for_range")
            }
            return nil
        }
        return text
    }

    private static func resolvedFocus(
        _ focus: FocusedElementIdentity,
        lease: NativeAXElementLease
    ) -> FocusedElementIdentity {
        FocusedElementIdentity(
            processID: focus.processID,
            bundleID: focus.bundleID,
            identifier: lease.identifier
        )
    }

    private static func remainingMilliseconds(until deadline: DispatchTime) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return 0 }
        return Int((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
    }

    private func logLookupFailure(_ failure: FocusedEditableLookupFailure) {
        switch failure {
        case .noFocusedElement:
            rslog("ax_no_focused")
        case .noEditableElement:
            rslog("ax_no_editable")
        case .ambiguousFocusedElements:
            rslog("ax_ambiguous_focused")
        case .timedOut:
            rslog("ax_timeout")
        case .identifierMismatch:
            rslog("ax_identifier_mismatch")
        }
    }

    private static func focusKey(_ focus: FocusedElementIdentity) -> String {
        "\(focus.processID):\(focus.identifier ?? "*")"
    }
}
