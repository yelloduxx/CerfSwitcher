import Foundation

public struct InputMethodCompositionPreferences: Sendable {
    public let automaticConversionEnabled: Bool
    public let policy: AutoConvertPolicy
    public let adaptiveRules: AdaptiveRuleBook
    public let appBundleID: String?

    public init(
        automaticConversionEnabled: Bool = true,
        policy: AutoConvertPolicy = .empty,
        adaptiveRules: AdaptiveRuleBook = AdaptiveRuleBook(),
        appBundleID: String? = nil
    ) {
        self.automaticConversionEnabled = automaticConversionEnabled
        self.policy = policy
        self.adaptiveRules = adaptiveRules
        self.appBundleID = appBundleID
    }
}

public struct InputMethodCompositionResolution: Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let sourceLanguage: String
    public let resolvedLanguage: String
    public let wasConverted: Bool
    public let reason: AutoConvertDecisionReason
    public let evidence: [DecoderEvidence]

    public init(
        original: String,
        replacement: String,
        sourceLanguage: String,
        resolvedLanguage: String,
        wasConverted: Bool,
        reason: AutoConvertDecisionReason,
        evidence: [DecoderEvidence]
    ) {
        self.original = original
        self.replacement = replacement
        self.sourceLanguage = sourceLanguage
        self.resolvedLanguage = resolvedLanguage
        self.wasConverted = wasConverted
        self.reason = reason
        self.evidence = evidence
    }
}

/// Owns only text that is still marked by an InputMethodKit client. Resolving a
/// token therefore never needs to delete already committed editor contents.
public struct InputMethodCompositionSession {
    public private(set) var token = ""
    public private(set) var currentLanguage: String
    public private(set) var contextWords: [String] = []
    public private(set) var languageBelief = LanguageBelief.neutral

    private let model: LanguageModelStore
    private var capsLockWasActive = false

    public init(currentLanguage: String, model: LanguageModelStore) {
        self.currentLanguage = LanguageCode.canonical(currentLanguage)
        self.model = model
    }

    public mutating func beginLanguage(_ language: String) {
        guard token.isEmpty else { return }
        currentLanguage = LanguageCode.canonical(language)
    }

    public mutating func append(_ text: String, capsLock: Bool = false) {
        token += text
        capsLockWasActive = capsLockWasActive || capsLock
    }

    @discardableResult
    public mutating func deleteBackward() -> Bool {
        guard !token.isEmpty else { return false }
        token.removeLast()
        if token.isEmpty { capsLockWasActive = false }
        return true
    }

    public mutating func replaceMarkedToken(with text: String) {
        token = text
        capsLockWasActive = false
    }

    public mutating func forceToggle() -> InputMethodCompositionResolution? {
        guard !token.isEmpty else { return nil }
        let original = token
        let replacement = KeyMapping.convert(original)
        guard replacement != original else { return nil }
        let sourceLanguage = LanguageCode.canonical(currentLanguage)
        let resolvedLanguage = sourceLanguage == "ru" ? "en" : "ru"
        token = ""
        capsLockWasActive = false
        currentLanguage = resolvedLanguage
        recordContext(text: replacement, language: resolvedLanguage)
        return InputMethodCompositionResolution(
            original: original,
            replacement: replacement,
            sourceLanguage: sourceLanguage,
            resolvedLanguage: resolvedLanguage,
            wasConverted: true,
            reason: .confirmedByUser,
            evidence: [.confirmedByUser]
        )
    }

    public mutating func resolve(
        preferences: InputMethodCompositionPreferences = InputMethodCompositionPreferences()
    ) -> InputMethodCompositionResolution? {
        guard !token.isEmpty else { return nil }

        let original = token
        let sourceLanguage = LanguageCode.canonical(currentLanguage)
        let targetLanguage = sourceLanguage == "ru" ? "en" : "ru"
        let evaluation: LayoutDecoderEvaluation?
        if preferences.automaticConversionEnabled,
           Set([sourceLanguage, targetLanguage]) == Set(["en", "ru"]) {
            let rules = preferences.adaptiveRules
            evaluation = LayoutDecoder.evaluate(
                typed: original,
                converted: KeyMapping.convert(original),
                currentLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                capsLock: capsLockWasActive,
                contextWords: contextWords,
                languageBelief: languageBelief,
                policy: preferences.policy,
                adaptiveBias: { typed, converted in
                    guard !ManualLearningPolicy.isLikelyReverseConversion(
                        original: typed,
                        converted: converted,
                        model: model
                    ) else { return 0 }
                    return rules.bias(
                        original: typed,
                        converted: converted,
                        appBundleID: preferences.appBundleID
                    )
                },
                isConfirmed: { typed, converted in
                    !ManualLearningPolicy.isLikelyReverseConversion(
                        original: typed,
                        converted: converted,
                        model: model
                    ) && rules.isConfirmed(
                        original: typed,
                        converted: converted,
                        appBundleID: preferences.appBundleID
                    )
                },
                model: model
            )
        } else {
            evaluation = nil
        }

        let shouldConvert = evaluation?.decision.verdict == .switchToConverted
        let replacement = shouldConvert
            ? evaluation?.decision.candidate.replacement ?? original
            : original
        let resolvedLanguage = shouldConvert ? targetLanguage : sourceLanguage
        let reason = evaluation?.decision.reason ?? .keepCurrentWord
        let evidence = evaluation?.evidence ?? []

        token = ""
        capsLockWasActive = false
        recordContext(text: replacement, language: resolvedLanguage)
        if shouldConvert { currentLanguage = targetLanguage }

        return InputMethodCompositionResolution(
            original: original,
            replacement: replacement,
            sourceLanguage: sourceLanguage,
            resolvedLanguage: resolvedLanguage,
            wasConverted: shouldConvert,
            reason: reason,
            evidence: evidence
        )
    }

    public mutating func takeLiteralWithoutContext() -> String? {
        guard !token.isEmpty else { return nil }
        defer {
            token = ""
            capsLockWasActive = false
        }
        return token
    }

    public mutating func resetContext() {
        contextWords.removeAll(keepingCapacity: true)
        languageBelief = .neutral
    }

    private mutating func recordContext(text: String, language: String) {
        let lexical = SmartTokenizer.lexicalCore(of: text)
        if !lexical.isEmpty {
            contextWords.append(text)
            if contextWords.count > 16 {
                contextWords.removeFirst(contextWords.count - 16)
            }
        }
        languageBelief.observe(language: language)
    }
}
