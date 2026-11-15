import Foundation

public enum LayoutVerdict: Equatable, Sendable {
    case switchToConverted
    case keep
    case undecided
}

public enum AutoConvertDecisionReason: Equatable, Sendable {
    case frequentShort
    case frequentWord
    case dictionary
    case scriptScore
    case characterModel
    case calibratedScore
    case phraseContext
    case compound
    case confirmedByUser
    case blockedNever
    case blockedCodeLike
    case blockedContext
    case blockedLearned
    case blockedEditing
    case keepCurrentWord
    case alwaysConvert
    case undecided
}

public struct AutoConvertDecision: Equatable, Sendable {
    public let verdict: LayoutVerdict
    public let reason: AutoConvertDecisionReason
    public let candidate: AutoConvertCandidate

    public init(
        verdict: LayoutVerdict,
        reason: AutoConvertDecisionReason,
        candidate: AutoConvertCandidate
    ) {
        self.verdict = verdict
        self.reason = reason
        self.candidate = candidate
    }
}

public struct AutoConvertPolicy: Equatable, Sendable {
    public let neverConvert: Set<String>
    public let alwaysConvert: Set<String>

    public static let empty = AutoConvertPolicy(neverConvert: [], alwaysConvert: [])

    public init(neverConvert: Set<String>, alwaysConvert: Set<String>) {
        self.neverConvert = Set(neverConvert.map {
            FrequentWordLexicon.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.isEmpty })
        self.alwaysConvert = alwaysConvert
    }

    /// Either spelling excludes the physical-layout pair, including wrappers.
    public func excludes(original: String, converted: String) -> Bool {
        guard !neverConvert.isEmpty else { return false }
        return [original, converted].contains { text in
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return neverConvert.contains(FrequentWordLexicon.normalize(word))
                || neverConvert.contains(FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: word)))
        }
    }
}
