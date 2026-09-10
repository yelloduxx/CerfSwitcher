import Foundation
import RuSwitcherCore

public enum TextContextPreflight: Equatable, Sendable {
    case matched(TextReplacementAnchor)
    case mismatch
    case unavailable
}

/// Transient read-only evidence for one edit. The short prefix is never logged
/// or persisted; verifying only the replacement suffix cannot detect leftovers.
public struct TextReplacementAnchor: Equatable, Sendable {
    public static let maximumPrefixUTF16Length = 64

    public let focus: FocusedElementIdentity
    private let rangeStart: Int
    private let prefix: String

    public static func capture(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        selection: NSRange,
        capturedRange: NSRange,
        capturedText: String
    ) -> TextContextPreflight {
        guard focus.processID > 0, let identifier = focus.identifier, !identifier.isEmpty else { return .unavailable }
        let length = expectedSuffix.utf16.count
        guard length > 0, selection.location != NSNotFound,
              selection.location >= length, selection.length == 0 else { return .mismatch }
        guard capturedRange.location >= 0, capturedRange.location != NSNotFound, capturedRange.length >= length,
              capturedRange.location <= selection.location,
              capturedRange.length == selection.location - capturedRange.location,
              capturedText.utf16.count == capturedRange.length else { return .unavailable }
        let prefixLength = capturedRange.length - length
        guard prefixLength <= maximumPrefixUTF16Length,
              let suffixRange = Range(NSRange(location: prefixLength, length: length), in: capturedText),
              capturedText.indices.contains(suffixRange.lowerBound) else { return .unavailable }
        guard capturedText[suffixRange].utf16.elementsEqual(expectedSuffix.utf16) else { return .mismatch }
        return .matched(Self(focus: focus, rangeStart: capturedRange.location,
                             prefix: String(capturedText[..<suffixRange.lowerBound])))
    }

    public func expectedSelection(replacement: String) -> NSRange? {
        guard let range = expectedRange(replacement: replacement) else { return nil }
        let (location, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : NSRange(location: location, length: 0)
    }

    public func expectedRange(replacement: String) -> NSRange? {
        let (length, overflow) = prefix.utf16.count.addingReportingOverflow(replacement.utf16.count)
        guard !overflow, rangeStart <= Int.max - length else { return nil }
        return NSRange(location: rangeStart, length: length)
    }

    public func verify(
        replacement: String,
        focus: FocusedElementIdentity,
        selection: NSRange,
        capturedRange: NSRange,
        capturedText: String
    ) -> TextContextValidation {
        guard focus == self.focus,
              let expectedSelection = expectedSelection(replacement: replacement),
              selection == expectedSelection else { return .mismatch }
        guard capturedRange == expectedRange(replacement: replacement),
              capturedText.utf16.count == capturedRange.length else { return .unavailable }
        return capturedText.utf16.elementsEqual((prefix + replacement).utf16) ? .match : .mismatch
    }
}
