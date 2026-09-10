import Foundation

/// An in-memory editor with UTF-16 selection offsets and grapheme-based editing.
public struct VirtualTextEditor {
    public enum SelectionError: Error, Equatable {
        case invalidRange(NSRange)
    }

    public private(set) var text: String
    public private(set) var selectedRange: NSRange
    public private(set) var revision: UInt64 = 0

    private var caret: Int
    private var anchor: Int

    /// Starts with the caret at the end; initial text is not an edit.
    public init(text: String = "") {
        self.text = text
        caret = text.utf16.count
        anchor = caret
        selectedRange = NSRange(location: caret, length: 0)
    }

    public mutating func insert(_ text: String) {
        let lower = String.Index(utf16Offset: selectedRange.location, in: self.text)
        let upper = String.Index(utf16Offset: NSMaxRange(selectedRange), in: self.text)
        replace(lower..<upper, with: text)
    }

    public mutating func backspace() {
        if selectedRange.length > 0 {
            insert("")
        } else if caret > 0 {
            let end = String.Index(utf16Offset: caret, in: text)
            replace(text.index(before: end)..<end, with: "")
        }
    }

    /// Both endpoints must be grapheme boundaries. The upper endpoint is active.
    public mutating func setSelection(_ range: NSRange) throws {
        let length = text.utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location,
              let indices = Range(range, in: text),
              isGraphemeBoundary(indices.lowerBound), isGraphemeBoundary(indices.upperBound) else {
            throw SelectionError.invalidRange(range)
        }
        update(text: text, anchor: range.location, caret: NSMaxRange(range))
    }

    /// Repeats arrow movement, clamped to the text. Without extension, the first
    /// step collapses a selection toward the movement direction.
    public mutating func moveCaret(byCharacters distance: Int, extendingSelection: Bool = false) {
        guard distance != 0 else { return }
        let boundaries = text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
        var start = caret
        var remaining = distance
        if !extendingSelection, selectedRange.length > 0 {
            start = distance < 0 ? selectedRange.location : NSMaxRange(selectedRange)
            remaining += distance < 0 ? 1 : -1
        }
        // Every stored caret is a boundary, including after grapheme resegmentation.
        guard var position = boundaries.firstIndex(of: start) else {
            preconditionFailure("Caret must be at a grapheme boundary")
        }
        if remaining > 0 {
            position += min(remaining, boundaries.count - 1 - position)
        } else {
            position += max(remaining, -position)
        }
        let next = boundaries[position]
        update(text: text, anchor: extendingSelection ? anchor : next, caret: next)
    }

    /// Checks the active caret, which may be the lower endpoint of a selection.
    public func hasSuffixBeforeCaret(_ suffix: String) -> Bool {
        let end = String.Index(utf16Offset: caret, in: text)
        return text[..<end].hasSuffix(suffix)
    }

    private func isGraphemeBoundary(_ index: String.Index) -> Bool {
        index == text.endIndex || text.indices.contains(index)
    }

    private mutating func replace(_ range: Range<String.Index>, with replacement: String) {
        let insertionEnd = range.lowerBound.utf16Offset(in: text) + replacement.utf16.count
        var edited = text
        edited.replaceSubrange(range, with: replacement)
        // An edit can merge neighboring graphemes. Snap forward past the merged
        // grapheme rather than leaving a caret inside it.
        let next = edited.indices.first { $0.utf16Offset(in: edited) >= insertionEnd }
            .map { $0.utf16Offset(in: edited) } ?? edited.utf16.count
        update(text: edited, anchor: next, caret: next)
    }

    private mutating func update(text: String, anchor: Int, caret: Int) {
        let range = NSRange(location: min(anchor, caret), length: max(anchor, caret) - min(anchor, caret))
        // Canonically equivalent strings can still have different UTF-16 storage.
        guard !self.text.utf16.elementsEqual(text.utf16) || selectedRange != range || self.caret != caret else {
            return
        }
        self.text = text
        self.anchor = anchor
        self.caret = caret
        selectedRange = range
        revision += 1
    }
}
