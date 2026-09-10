import Foundation
import RuSwitcherCore

@MainActor
public protocol ReplacementCompletionScheduling {
    /// Always enqueue; never call inline before the token has been staged.
    func enqueue(_ action: @escaping @MainActor () -> Void)
}

public struct MainQueueReplacementScheduler: ReplacementCompletionScheduling {
    public init() {}
    public func enqueue(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { action() }
    }
}

public struct AutomaticReplacementSubmission: Equatable, Sendable {
    public let outcome: ReplacementOutcome
    public let handling: TokenHandlingResult

    public var isNewPost: Bool { outcome == .postedUnverified }
}

public struct AutomaticReplacementState: Equatable, Sendable {
    public let focus: FocusedElementIdentity?
    public let sequence: UInt64
    public let editRevision: UInt64
    public let integrity: EditorIntegrity
    public let hasCurrentToken: Bool

    public init(focus: FocusedElementIdentity?, sequence: UInt64, editRevision: UInt64,
                integrity: EditorIntegrity, hasCurrentToken: Bool) {
        self.focus = focus
        self.sequence = sequence
        self.editRevision = editRevision
        self.integrity = integrity
        self.hasCurrentToken = hasCurrentToken
    }
}

public enum AutomaticReplacementCompletion: Equatable, Sendable {
    case confirm
    case retainUnverified
    case invalidate
    case discard
    case ignore
}

/// Shared post/acknowledgement lifecycle. Layout is changed on post only; a
/// delayed acknowledgement never overrides a later input-source choice.
@MainActor
public final class AutomaticReplacementDriver {
    private let coordinator: ReplacementCoordinating
    private let scheduler: ReplacementCompletionScheduling

    public init(coordinator: ReplacementCoordinating,
                scheduler: ReplacementCompletionScheduling = MainQueueReplacementScheduler()) {
        self.coordinator = coordinator
        self.scheduler = scheduler
    }

    private final class Acknowledgement {
        var accepted = false
        var delivered = false
    }

    public func submit(
        _ request: ReplacementRequest,
        sourceLanguage: String,
        targetLanguage: String,
        switchLayout: (String?) -> Void,
        completion: @escaping @MainActor (ReplacementOutcome) -> Void
    ) -> AutomaticReplacementSubmission {
        let acknowledgement = Acknowledgement()
        let outcome = coordinator.submit(request) { [scheduler] result in
            scheduler.enqueue {
                guard acknowledgement.accepted, !acknowledgement.delivered else { return }
                acknowledgement.delivered = true
                completion(result)
            }
        }
        acknowledgement.accepted = outcome == .postedUnverified
        let transaction = request.transaction
        let handling: TokenHandlingResult
        switch outcome {
        case .postedUnverified:
            switchLayout(transaction.targetLayoutID)
            handling = TokenHandlingResult(
                consumeBoundary: transaction.boundary.shouldConsumeOriginalEvent,
                stageCompletion: true, resolvedText: transaction.replacement,
                resolvedLanguage: targetLanguage, wasConverted: true
            )
        case .blocked(.duplicateTransaction):
            // A repeated callback is not a new input decision. Do not repeat
            // the layout switch or append/stage a second context observation.
            handling = TokenHandlingResult(
                consumeBoundary: transaction.boundary.shouldConsumeOriginalEvent,
                finalizeToken: false, resolvedText: nil, resolvedLanguage: nil, wasConverted: false
            )
        case .verified, .switchedOnly, .blocked, .failed:
            handling = TokenHandlingResult(
                consumeBoundary: false, resolvedText: transaction.original,
                resolvedLanguage: sourceLanguage, wasConverted: false,
                invalidateSession: outcome != .verified
            )
        }
        return AutomaticReplacementSubmission(outcome: outcome, handling: handling)
    }

    public nonisolated static func completion(
        for outcome: ReplacementOutcome,
        transaction: ConversionTransaction,
        state: AutomaticReplacementState
    ) -> AutomaticReplacementCompletion {
        guard let focus = state.focus,
              focus.processID == transaction.focus.processID,
              focus.bundleID == transaction.focus.bundleID else { return .discard }
        // Known element identities must agree. An absent cached identity is not
        // permission to confirm a transaction that named a specific field.
        if let expected = transaction.focus.identifier, focus.identifier != expected { return .discard }
        guard state.sequence == transaction.sequence &+ 1,
              state.editRevision == transaction.editRevision,
              state.integrity == .clean, !state.hasCurrentToken else { return .ignore }
        switch outcome {
        case .verified: return .confirm
        case .postedUnverified: return .retainUnverified
        case .failed(.verificationMismatch): return .invalidate
        case .failed, .blocked, .switchedOnly: return .discard
        }
    }
}
