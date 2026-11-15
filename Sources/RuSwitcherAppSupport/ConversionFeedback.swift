import Foundation
import RuSwitcherCore

public enum ConversionRefusal: Equatable, Sendable {
    case disabled, secureInput, excludedApplication, wordRule, protectedText
    case uncertain, fieldUnavailable, editorChanged, unsupportedLayout, modelUnavailable
    case busy, deliveryFailed, verificationFailed
}

public enum ConversionAttemptResult: Equatable, Sendable {
    case converted, unverified, kept, switchedOnly
    case refused(ConversionRefusal)

    public init(outcome: ReplacementOutcome) {
        switch outcome {
        case .verified: self = .converted
        case .postedUnverified: self = .unverified
        case .switchedOnly: self = .switchedOnly
        case .blocked(.contextUnavailable): self = .refused(.fieldUnavailable)
        case .blocked(.secureInput): self = .refused(.secureInput)
        case .blocked(.deniedApplication): self = .refused(.excludedApplication)
        case .blocked(.ambiguousDeletion): self = .refused(.protectedText)
        case .blocked: self = .refused(.editorChanged)
        case .failed(.eventPostFailed): self = .refused(.deliveryFailed)
        case .failed(.verificationMismatch): self = .refused(.verificationFailed)
        }
    }

    public init(keptBecause reason: AutoConvertDecisionReason?) {
        switch reason {
        case .blockedNever, .blockedLearned: self = .refused(.wordRule)
        case .blockedCodeLike: self = .refused(.protectedText)
        case .blockedEditing: self = .refused(.editorChanged)
        case .blockedContext, .undecided, nil: self = .refused(.uncertain)
        default: self = .kept
        }
    }
}

/// Ephemeral result codes only. An older async result cannot describe a newer attempt.
public struct ConversionFeedback: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case manual, automatic }

    public struct Attempt: Equatable, Sendable {
        fileprivate let generation: UInt64
        public let source: Source
    }

    public struct Entry: Equatable, Sendable {
        public let attempt: Attempt
        public let result: ConversionAttemptResult
        public let at: Date
    }

    private var generation: UInt64 = 0
    public private(set) var latest: Entry?

    public init() {}

    public mutating func begin(_ source: Source) -> Attempt {
        generation &+= 1
        return Attempt(generation: generation, source: source)
    }

    public func isCurrent(_ attempt: Attempt) -> Bool {
        attempt.generation == generation
    }

    public mutating func invalidatePending() {
        generation &+= 1
    }

    @discardableResult
    public mutating func record(_ result: ConversionAttemptResult, for attempt: Attempt,
                                at date: Date = Date()) -> Bool {
        guard isCurrent(attempt) else { return false }
        latest = Entry(attempt: attempt, result: result, at: date)
        return true
    }

    public mutating func clear() {
        invalidatePending()
        latest = nil
    }
}
