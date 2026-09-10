import Foundation

/// An automatic switch can overtake keys already waiting in the system queue.
/// Bind those keys to the same layout used by the token session, without
/// deleting, reposting, or waiting for any further input.
public struct QueuedLayoutTransition {
    private var targetLayoutID: String?
    private var completedAt: UInt64 = 0

    public init() {}

    public mutating func record(targetLayoutID: String, completedAt: UInt64) {
        self.targetLayoutID = targetLayoutID
        self.completedAt = completedAt
    }

    public mutating func reset() {
        targetLayoutID = nil
        completedAt = 0
    }

    public mutating func overrideText(eventTimestamp: UInt64, layoutID: String?, translatedText: String?) -> String? {
        guard let targetLayoutID else { return nil }
        guard layoutID == targetLayoutID, eventTimestamp > 0, eventTimestamp <= completedAt,
              let text = translatedText, text.utf16.count == 1,
              let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.nonBaseCharacters.contains(scalar) else {
            reset()
            return nil
        }
        return text
    }
}
