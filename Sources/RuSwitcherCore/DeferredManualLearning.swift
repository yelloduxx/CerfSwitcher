public struct DeferredManualLearningCandidate: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let appBundleID: String?

    public init(original: String, converted: String, appBundleID: String?) {
        self.original = original
        self.converted = converted
        self.appBundleID = appBundleID
    }
}

/// Keeps an explicitly requested manual correction provisional until the user
/// accepts it or a short grace period expires. A generation prevents a stale
/// timer from confirming a correction that was reversed or superseded.
public struct DeferredManualLearningGate: Sendable {
    private struct Pending: Sendable {
        let generation: UInt64
        let candidate: DeferredManualLearningCandidate
    }

    private var generation: UInt64 = 0
    private var pending: Pending?

    public init() {}

    @discardableResult
    public mutating func stage(_ candidate: DeferredManualLearningCandidate) -> UInt64 {
        generation &+= 1
        pending = Pending(generation: generation, candidate: candidate)
        return generation
    }

    public mutating func accept(expectedGeneration: UInt64) -> DeferredManualLearningCandidate? {
        guard let pending,
              expectedGeneration == pending.generation else {
            return nil
        }
        self.pending = nil
        return pending.candidate
    }

    public mutating func cancel() {
        generation &+= 1
        pending = nil
    }

    public var hasPendingCandidate: Bool {
        pending != nil
    }

    public var pendingGeneration: UInt64? { pending?.generation }
}
