public enum ManualLearningPolicy {
    /// A forced toggle is not automatically a correction. A known valid word
    /// toggled into an unknown keyboard-equivalent string must not become a
    /// global automatic rule.
    public static func shouldPersist(
        original: String,
        converted: String,
        model: LanguageModelStore?
    ) -> Bool {
        guard model != nil else { return false }
        return !isLikelyReverseConversion(
            original: original,
            converted: converted,
            model: model
        )
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
