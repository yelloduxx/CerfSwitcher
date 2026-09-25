import Foundation

public enum ManualLearningDecision: Equatable, Sendable {
    case ignore
    case confirmation(original: String, converted: String, clearingExceptionFor: String?)
    case applicationException(original: String, converted: String, appBundleID: String)

    public func apply(to book: inout AdaptiveRuleBook) {
        switch self {
        case .ignore: break
        case let .confirmation(original, converted, appBundleID):
            book.recordConfirmed(original: original, converted: converted, clearingExceptionFor: appBundleID)
        case let .applicationException(original, converted, appBundleID):
            book.recordNegative(original: original, converted: converted, appBundleID: appBundleID)
        }
    }
}

public enum ManualLearningPolicy {
    /// The undo of a confirmed global pair is an application preference, not a
    /// proposal to teach the dictionary its opposite spelling.
    public static func decision(
        original: String, converted: String, appBundleID: String?,
        ruleBook: AdaptiveRuleBook, model: LanguageModelStore?
    ) -> ManualLearningDecision {
        let sourceText = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetText = converted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLearnableTokenShape(sourceText), isLearnableTokenShape(targetText) else { return .ignore }
        let source = FrequentWordLexicon.normalize(sourceText)
        let target = FrequentWordLexicon.normalize(targetText)
        guard source != target else { return .ignore }
        if ruleBook.isConfirmed(original: target, converted: source, appBundleID: nil) {
            guard let appBundleID, !appBundleID.isEmpty else { return .ignore }
            return .applicationException(original: target, converted: source, appBundleID: appBundleID)
        }
        guard shouldPersist(original: source, converted: target, model: model) else { return .ignore }
        return .confirmation(original: source, converted: target, clearingExceptionFor: appBundleID)
    }

    /// A forced toggle is not automatically a correction. A known valid word
    /// toggled into an unknown keyboard-equivalent string must not become a
    /// global automatic rule.
    public static func shouldPersist(
        original: String,
        converted: String,
        model: LanguageModelStore?
    ) -> Bool {
        guard model != nil,
              isLearnableTokenShape(original),
              isLearnableTokenShape(converted) else { return false }
        return !isLikelyReverseConversion(
            original: original,
            converted: converted,
            model: model
        )
    }

    public static func isLearnableTokenShape(_ text: String) -> Bool {
        guard text.count <= LearnedCorrectionsArchive.maximumTokenLength,
              !text.contains(where: \.isWhitespace), text.count(where: \.isLetter) >= 2 else { return false }
        return SmartTokenizer.kind(of: text) == .lexical
            || SmartTokenizer.isAllUppercaseWord(text)
    }

    public static func isLikelyReverseConversion(
        original: String,
        converted: String,
        model: LanguageModelStore?
    ) -> Bool {
        guard let model else { return false }
        let source = SmartTokenizer.lexicalCore(of: original)
        let target = SmartTokenizer.lexicalCore(of: converted)
        guard !source.isEmpty,
              !target.isEmpty,
              let sourceLanguage = SmartTokenizer.languageHint(for: source),
              let targetLanguage = SmartTokenizer.languageHint(for: target),
              sourceLanguage != targetLanguage else { return false }
        return isKnown(source, language: sourceLanguage, model: model)
            && !isKnown(target, language: targetLanguage, model: model)
    }

    private static func isKnown(
        _ word: String,
        language: String,
        model: LanguageModelStore
    ) -> Bool {
        if FrequentWordLexicon.contains(word, language: language)
            || model.contains(word, language: language) {
            return true
        }
        switch String(language.lowercased().prefix(2)) {
        case "en": return model.isExtendedEnglishWord(word)
        case "ru": return model.isExtendedRussianWord(word)
        default: return false
        }
    }
}
