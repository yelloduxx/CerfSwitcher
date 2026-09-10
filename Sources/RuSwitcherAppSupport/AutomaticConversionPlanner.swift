import Foundation
import RuSwitcherCore

public enum AutomaticConversionPlan: Equatable, Sendable {
    case keep(TokenHandlingResult, evaluation: LayoutDecoderEvaluation?)
    case replace(ReplacementRequest, evaluation: LayoutDecoderEvaluation)

    public var evaluation: LayoutDecoderEvaluation? {
        switch self {
        case let .keep(_, evaluation): return evaluation
        case let .replace(_, evaluation): return evaluation
        }
    }
}

/// Shared decoder-to-request preparation. Native callers resolve physical
/// layouts and host permissions; this layer never reads or changes the editor.
public enum AutomaticConversionPlanner {
    public static func prepare(
        snapshot: TokenSnapshot,
        original: String,
        converted: String,
        currentLanguage: String?,
        targetLanguage: String?,
        targetLayoutID: @autoclosure () -> String?,
        policy: AutoConvertPolicy = .empty,
        allowUnavailablePost: Bool = false,
        adaptiveBias: (String, String) -> Double = { _, _ in 0 },
        isConfirmed: (String, String) -> Bool = { _, _ in false },
        model: LanguageModelStore?,
        at: Date = Date()
    ) -> AutomaticConversionPlan {
        if policy.neverConvert.contains(original.lowercased()) || policy.neverConvert.contains(converted.lowercased()) {
            return .keep(.init(consumeBoundary: false, resolvedText: original,
                               resolvedLanguage: SmartTokenizer.languageHint(for: original), wasConverted: false), evaluation: nil)
        }
        guard let currentLanguage, let targetLanguage else { return .keep(.passThrough, evaluation: nil) }
        let languages = Set([String(currentLanguage.lowercased().prefix(2)), String(targetLanguage.lowercased().prefix(2))])
        guard languages == Set(["en", "ru"]), let model else {
            return .keep(.init(consumeBoundary: false, resolvedText: original,
                               resolvedLanguage: currentLanguage, wasConverted: false), evaluation: nil)
        }
        let evaluation = LayoutDecoder.evaluate(
            typed: original, converted: converted, currentLanguage: currentLanguage, targetLanguage: targetLanguage,
            capsLock: snapshot.keys.contains(where: \.caps), contextWords: snapshot.context.map(\.text),
            languageBelief: snapshot.languageBelief, integrity: snapshot.integrity,
            policy: policy, adaptiveBias: adaptiveBias, isConfirmed: isConfirmed, model: model
        )
        guard evaluation.decision.verdict == .switchToConverted else {
            let finalize: Bool
            if case .punctuation = snapshot.boundary, evaluation.decision.verdict == .undecided {
                finalize = false
            } else {
                finalize = true
            }
            return .keep(.init(consumeBoundary: false, finalizeToken: finalize, resolvedText: original,
                               resolvedLanguage: currentLanguage, wasConverted: false), evaluation: evaluation)
        }
        let undeliveredCount = snapshot.boundary.isIncludedInTokenKeys ? 1 : 0
        let transaction = ConversionTransaction(
            original: original, replacement: evaluation.decision.candidate.replacement, boundary: snapshot.boundary,
            focus: snapshot.focus, sourceLayoutID: snapshot.sourceLayoutID, targetLayoutID: targetLayoutID(),
            sequence: snapshot.sequence, editRevision: snapshot.editRevision,
            expectedOriginalSuffix: String(original.dropLast(undeliveredCount)), createdAt: at, automatic: true
        )
        return .replace(.init(transaction: transaction, deliveredKeyCount: snapshot.deliveredKeyCount,
                              currentFocus: snapshot.focus, currentRevision: snapshot.editRevision,
                              allowUnavailablePost: allowUnavailablePost), evaluation: evaluation)
    }
}
