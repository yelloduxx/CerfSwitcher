import Foundation

public enum DecoderEvidence: Equatable, Sendable {
    case frequent
    case characterModel
    case phraseContext
    case compound(segmentLengths: [Int])
    case confirmedByUser
    case blockedCode
    case blockedNever
    case blockedEditing
    case blockedContext
    case neuralContext
    case codeSwitch
    case punctuationPath
    case personalized
    case abstained
    case englishSourceFrequent
    case englishSourceDictionary
    case englishSourcePlausible
    case englishSourceUnlikely
    case englishTargetDictionary
    case russianSourceDictionary
    case russianTargetDictionary
    case calibrated
}

public struct LayoutDecoderEvaluation: Equatable, Sendable {
    public let decision: AutoConvertDecision
    public let literalScore: Double
    public let convertedScore: Double
    public let threshold: Double
    public let evidence: [DecoderEvidence]
    /// Features of a word the rules left undecided, for the calibrated score
    /// and for refitting it offline.
    public let calibrationFeatures: [String: Double]?

    public var confidenceMargin: Double { convertedScore - literalScore }

    public init(
        decision: AutoConvertDecision,
        literalScore: Double,
        convertedScore: Double,
        threshold: Double,
        evidence: [DecoderEvidence],
        calibrationFeatures: [String: Double]? = nil
    ) {
        self.decision = decision
        self.literalScore = literalScore
        self.convertedScore = convertedScore
        self.threshold = threshold
        self.evidence = evidence
        self.calibrationFeatures = calibrationFeatures
    }
}

public enum LayoutDecoder {
    public static func evaluate(
        typed: String,
        converted: String,
        currentLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        contextWords: [String],
        languageBelief: LanguageBelief,
        integrity: EditorIntegrity = .clean,
        policy: AutoConvertPolicy,
        adaptiveBias: (String, String) -> Double = { _, _ in 0 },
        isConfirmed: (String, String) -> Bool = { _, _ in false },
        model: LanguageModelStore
    ) -> LayoutDecoderEvaluation {
        let generated = AutoConvertCandidateGenerator.candidates(typed: typed, converted: converted)
        if !typed.contains(where: \.isLetter) {
            let candidate = generated.first ?? AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: converted,
                suffix: "",
                kind: .directWord
            )
            return fixed(candidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }
        let targetCanonical = LanguageCode.canonical(targetLanguage)
        func candidateWord(_ candidate: AutoConvertCandidate) -> String {
            FrequentWordLexicon.normalize(
                SmartTokenizer.lexicalCore(of: candidate.convertedWord)
            )
        }
        func isTargetWord(_ candidate: AutoConvertCandidate) -> Bool {
            let word = candidateWord(candidate)
            return model.attestedWordLogProbability(word, language: targetCanonical) != nil
                || (targetCanonical == "en" && model.isExtendedEnglishWord(word))
                || (targetCanonical == "ru" && model.isExtendedRussianWord(word))
        }
        let frequentCandidates = generated.filter { candidate in
            let word = candidateWord(candidate)
            return model.wordLogProbability(word, language: targetCanonical) != nil
                || FrequentWordLexicon.contains(word, language: targetCanonical)
        }
        let spellingCandidates = generated.filter { candidate in
            let word = candidateWord(candidate)
            return (targetCanonical == "en" && model.isExtendedEnglishWord(word))
                || (targetCanonical == "ru" && model.isExtendedRussianWord(word))
        }
        // A word that keeps a leading layout-letter key as punctuation faces an
        // attested reading of that key as a letter: `<fdfhbb` is `Баварии`,
        // not `<аварии`.
        func attestedPrefixReadings(against tier: [AutoConvertCandidate]) -> [AutoConvertCandidate] {
            guard tier.contains(where: preservesLayoutLetterPrefix) else { return [] }
            return generated.filter {
                !preservesLayoutLetterPrefix($0) && !preservesLayoutLetterSuffix($0) && !tier.contains($0)
                    && model.attestedWordLogProbability(candidateWord($0), language: targetCanonical) != nil
            }
        }
        func lexicalTargetStrength(_ evaluation: LayoutDecoderEvaluation) -> Int {
            let candidate = evaluation.decision.candidate
            if evaluation.evidence.contains(.confirmedByUser)
                || model.wordLogProbability(candidateWord(candidate), language: targetCanonical) != nil {
                return 2
            }
            let lexical = isTargetWord(candidate) || evaluation.evidence.contains {
                if case .compound = $0 { return true }
                return $0 == .englishTargetDictionary || $0 == .russianTargetDictionary
            }
            return lexical ? 1 : 0
        }
        let confirmedCandidates = generated.filter { candidate in
            isConfirmed(typed, candidate.replacement)
        }
        // Frequency evidence dominates spelling-only membership, which in turn
        // dominates character-only interpretations of the same physical keys.
        let candidates: [AutoConvertCandidate]
        if !confirmedCandidates.isEmpty {
            candidates = confirmedCandidates
        } else if !frequentCandidates.isEmpty {
            // A frequent word that keeps a `.`/`,` key as punctuation still faces
            // an attested word reading that key as a letter (`вероятностью`).
            let keepsLayoutLetterSuffix = frequentCandidates.contains(where: preservesLayoutLetterSuffix)
            let attestedLetterReadings = keepsLayoutLetterSuffix
                ? spellingCandidates.filter {
                    !preservesLayoutLetterSuffix($0) && !frequentCandidates.contains($0)
                        && model.attestedWordLogProbability(candidateWord($0), language: targetCanonical) != nil
                }
                : []
            candidates = frequentCandidates + attestedLetterReadings
                + attestedPrefixReadings(against: frequentCandidates + attestedLetterReadings)
        } else if !spellingCandidates.isEmpty {
            candidates = spellingCandidates + attestedPrefixReadings(against: spellingCandidates)
        } else {
            candidates = generated
        }
        let evaluations = candidates.map { candidate in
            evaluateCandidate(
                candidate,
                currentLanguage: currentLanguage,
                targetLanguage: targetLanguage,
                capsLock: capsLock,
                contextWords: contextWords,
                languageBelief: languageBelief,
                integrity: integrity,
                policy: policy,
                adaptiveBias: adaptiveBias(typed, candidate.replacement),
                confirmed: isConfirmed(typed, candidate.replacement),
                model: model
            )
        }
        return evaluations.max { lhs, rhs in
            if lhs.decision.verdict == .switchToConverted, rhs.decision.verdict != .switchToConverted { return false }
            if lhs.decision.verdict != .switchToConverted, rhs.decision.verdict == .switchToConverted { return true }
            // `[etvjt` must become `хуемое`, not `[уемое`. Preserving a leading
            // punctuation key that is a letter in the target layout is only safe
            // when that wrapping core is a real word (`[yt` → `[не`) and the
            // letter reading is not (`'njv` → `этом`, not `'том`).
            // A frequent wrapped core also outranks a letter reading known only
            // from attestation (`"lj` → `"до`, not `Эдо`), while an attested
            // reading beats a spelling-only core (`<fdfhbb` → `Баварии`).
            let lhsLayoutLetterPrefix = preservesLayoutLetterPrefix(lhs.decision.candidate)
            let rhsLayoutLetterPrefix = preservesLayoutLetterPrefix(rhs.decision.candidate)
            if lhsLayoutLetterPrefix != rhsLayoutLetterPrefix {
                let lhsCoreStrength = lexicalTargetStrength(lhs)
                let rhsCoreStrength = lexicalTargetStrength(rhs)
                if lhsLayoutLetterPrefix, lhsCoreStrength <= rhsCoreStrength { return true }
                if rhsLayoutLetterPrefix, rhsCoreStrength <= lhsCoreStrength { return false }
            }
            // The same holds at the end: the `.` and `,` keys are `ю` and `б` in
            // the Russian layout, so `xfcnm.` is `частью`, not `часть.`. Typed
            // punctuation stays only when the letter reading is not a word and
            // the wrapped core is (`ghbdtn,` → `привет,`, `Gtyl;f,` → `Пенджаб`).
            let lhsLayoutLetterSuffix = preservesLayoutLetterSuffix(lhs.decision.candidate)
            let rhsLayoutLetterSuffix = preservesLayoutLetterSuffix(rhs.decision.candidate)
            if lhsLayoutLetterSuffix != rhsLayoutLetterSuffix {
                if lhsLayoutLetterSuffix, isTargetWord(rhs.decision.candidate) || lexicalTargetStrength(lhs) == 0 {
                    return true
                }
                if rhsLayoutLetterSuffix, isTargetWord(lhs.decision.candidate) || lexicalTargetStrength(rhs) == 0 {
                    return false
                }
            }
            let lhsHasPhraseEvidence = lhs.evidence.contains(.phraseContext)
            let rhsHasPhraseEvidence = rhs.evidence.contains(.phraseContext)
            if lhsHasPhraseEvidence != rhsHasPhraseEvidence {
                return !lhsHasPhraseEvidence && rhsHasPhraseEvidence
            }
            let lhsCore = punctuationComparableCore(of: lhs.decision.candidate.replacement)
            let rhsCore = punctuationComparableCore(of: rhs.decision.candidate.replacement)
            let lhsDecoration = trailingDecoration(of: lhs.decision.candidate.replacement)
            let rhsDecoration = trailingDecoration(of: rhs.decision.candidate.replacement)
            if lhsCore == rhsCore,
               max(lhsDecoration.count, rhsDecoration.count) > 1 {
                let lhsPunctuationScore = punctuationSequenceScore(lhsDecoration)
                let rhsPunctuationScore = punctuationSequenceScore(rhsDecoration)
                if lhsPunctuationScore != rhsPunctuationScore {
                    return lhsPunctuationScore < rhsPunctuationScore
                }
            }
            let lhsUsesTranslatedSuffix = usesTranslatedPunctuationSuffix(lhs.decision.candidate)
            let rhsUsesTranslatedSuffix = usesTranslatedPunctuationSuffix(rhs.decision.candidate)
            if lhsUsesTranslatedSuffix != rhsUsesTranslatedSuffix {
                return !lhsUsesTranslatedSuffix && rhsUsesTranslatedSuffix
            }
            let lhsPreservesTypedSuffix = preservesTypedSuffix(lhs.decision.candidate)
            let rhsPreservesTypedSuffix = preservesTypedSuffix(rhs.decision.candidate)
            if lhsPreservesTypedSuffix != rhsPreservesTypedSuffix {
                return !lhsPreservesTypedSuffix && rhsPreservesTypedSuffix
            }
            if lhsPreservesTypedSuffix {
                let lhsDecoration = preservedDecorationCount(lhs.decision.candidate)
                let rhsDecoration = preservedDecorationCount(rhs.decision.candidate)
                if lhsDecoration != rhsDecoration {
                    return lhsDecoration < rhsDecoration
                }
            }
            if abs(lhs.convertedScore - rhs.convertedScore) > 0.000_001 {
                return lhs.convertedScore < rhs.convertedScore
            }
            return preservedDecorationCount(lhs.decision.candidate)
                < preservedDecorationCount(rhs.decision.candidate)
        } ?? fallback(typed: typed, converted: converted)
    }

    /// A word no dictionary knows converts only when it reads like the target
    /// language in absolute terms, `кринж` (-11.9) but not `Лщтфьш` (-15.0)
    /// from `Konami`, or when conversational text attests it (`Джеймса`).
    private static let unlistedTargetCharacterFloor = -13.0

    /// ln(1%): the previous word must lead to the target reading at least this often.
    private static let followerContinuationFloor = log(0.01)

    /// Natural-log margin (about 12x) a frequent target needs over the bound
    /// for an unlisted source spelling before frequency overrides membership.
    private static let rareSourceFrequencyMargin = 2.5

    private static func isUnusualInProse(_ character: Character) -> Bool {
        !character.isLetter && !character.isWhitespace && !".,!?;:()\"'«»-–—…".contains(character)
    }

    private static func preservedDecorationCount(_ candidate: AutoConvertCandidate) -> Int {
        candidate.prefix.count + candidate.suffix.count
    }

    private static func preservesTypedSuffix(_ candidate: AutoConvertCandidate) -> Bool {
        !candidate.suffix.isEmpty && candidate.typedRaw.hasSuffix(candidate.suffix)
    }

    /// True when a preserved prefix is punctuation in the typed layout but a letter
    /// after physical-key conversion (`[` → `х`, `,` → `б`).
    private static func preservesLayoutLetterPrefix(_ candidate: AutoConvertCandidate) -> Bool {
        guard !candidate.prefix.isEmpty else { return false }
        let convertedPrefix = KeyMapping.convert(candidate.prefix)
        return convertedPrefix.contains(where: \.isLetter)
    }

    /// A closing bracket is a natural word end (`yj]` → `он]`), so only other
    /// keys count, read in the conversion direction of this candidate.
    private static func preservesLayoutLetterSuffix(_ candidate: AutoConvertCandidate) -> Bool {
        preservesTypedSuffix(candidate)
            && !candidate.suffix.contains(where: { "]}".contains($0) })
            && candidate.convertedRaw.suffix(candidate.suffix.count).contains(where: \.isLetter)
    }


    /// When the same physical key is punctuation in both layouts, its target
    /// interpretation belongs to the converted token. Literal preservation is
    /// still preferred when the other layout would turn punctuation into a
    /// letter, as in `ghbdtn,` -> `привет,`.
    private static func usesTranslatedPunctuationSuffix(_ candidate: AutoConvertCandidate) -> Bool {
        guard candidate.suffix.count == 1,
              candidate.convertedRaw.hasSuffix(candidate.suffix),
              !candidate.typedRaw.hasSuffix(candidate.suffix) else { return false }
        let typedSuffix = candidate.typedRaw.suffix(candidate.suffix.count)
        return typedSuffix.allSatisfy(isDecoration)
            && candidate.suffix.allSatisfy(isDecoration)
    }

    private static func evaluateCandidate(
        _ candidate: AutoConvertCandidate,
        currentLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        contextWords: [String],
        languageBelief: LanguageBelief,
        integrity: EditorIntegrity,
        policy: AutoConvertPolicy,
        adaptiveBias: Double,
        confirmed: Bool,
        model: LanguageModelStore
    ) -> LayoutDecoderEvaluation {
        let typed = FrequentWordLexicon.normalize(candidate.typedRaw)
        let literal = SmartTokenizer.lexicalCore(of: typed)
        let converted = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        let shape = SmartTokenizer.shape(of: candidate.typedRaw)
        let convertedShape = SmartTokenizer.shape(of: candidate.replacement)
        let baseCandidate = candidate
        let currentCanonical = LanguageCode.canonical(currentLanguage)
        let targetCanonical = LanguageCode.canonical(targetLanguage)
        let targetKnownForShape = model.wordLogProbability(converted, language: targetCanonical)
        let targetEnglishTier = targetCanonical == "en"
            ? model.englishSpellingTier(converted)
            : nil
        let targetExtendedEnglish = targetEnglishTier != nil
        let targetExtendedRussian = targetCanonical == "ru" && model.isExtendedRussianWord(converted)
        let confirmedAcronymPair = confirmed
            && SmartTokenizer.isAllUppercaseWord(candidate.typedRaw)
            && SmartTokenizer.isAllUppercaseWord(candidate.replacement)

        if integrity != .clean {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedEditing, evidence: [.blockedEditing])
        }
        if policy.neverConvert.contains(typed) || policy.neverConvert.contains(converted) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedNever, evidence: [.blockedNever])
        }
        if literal.isEmpty {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }
        let sourceShapeIsProtected = shape.kind.blocksAutomaticConversion
            && !(convertedShape.kind == .lexical
                && (targetKnownForShape != nil || targetExtendedEnglish || targetExtendedRussian
                    || model.attestedWordLogProbability(converted, language: targetCanonical) != nil))
        // A lone capital is usually an initial or a letter name, except when it
        // is not a word at all and its other-layout key is: `Ш` → `I`, `(Ш)` →
        // `(I)`. A trailing period still marks an initial (`Ш.`). A Latin
        // capital becomes Russian only after Russian text or at the start
        // (`D` → `В`), never after English (`plan B`).
        let previousLanguage = contextWords.last
            .flatMap(SmartTokenizer.languageHint)
            .map(LanguageCode.canonical)
        let capitalIsOtherLayoutWord = literal.count == 1
            && !candidate.typedRaw.contains(".")
            && model.wordLogProbability(literal, language: currentCanonical) == nil
            && !(currentCanonical == "ru" && model.isExtendedRussianWord(literal))
            && targetKnownForShape != nil
            && (currentCanonical == "ru" || previousLanguage == nil || previousLanguage == targetCanonical)
        // A hyphenated word is a word when every part is (`премьер-министра`).
        func isWordOrHyphenatedWord(_ text: String, language: String) -> Bool {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            return parts.count >= 2 && parts.allSatisfy { part in
                !part.isEmpty
                    && (model.attestedWordLogProbability(part, language: language) != nil
                        || (language == "en" ? model.isExtendedEnglishWord(part) : model.isExtendedRussianWord(part)))
            }
        }
        // An all-caps part makes a code (`ru-RU`), not a hyphenated word.
        let typedHasCodePart = candidate.typedRaw.split(separator: "-").contains { part in
            let letters = part.filter(\.isLetter)
            return letters.count >= 2 && letters == letters.uppercased()
        }
        let hyphenatedTargetWord = !typedHasCodePart
            && isWordOrHyphenatedWord(converted, language: targetCanonical)
            && !isWordOrHyphenatedWord(literal, language: currentCanonical)
        // An acronym converts when its other reading is a word in use (`CIF/` →
        // `США.`) and its own letters spell no word.
        let typedLetters = candidate.typedRaw.filter(\.isLetter)
        let literalLetters = literal.filter(\.isLetter)
        let attestedAcronymPair = typedLetters.count >= 2
            && typedLetters == typedLetters.uppercased()
            && SmartTokenizer.isAllUppercaseWord(candidate.replacement)
            && model.attestedWordLogProbability(converted, language: targetCanonical) != nil
            && model.attestedWordLogProbability(literalLetters, language: currentCanonical) == nil
            && !(currentCanonical == "en" ? model.isExtendedEnglishWord(literalLetters) : model.isExtendedRussianWord(literalLetters))
        let softShapeOverride = confirmedAcronymPair || attestedAcronymPair || hyphenatedTargetWord
        if (SmartTokenizer.isSingleUppercaseLetter(candidate.typedRaw) && !capitalIsOtherLayoutWord)
            || (sourceShapeIsProtected && !softShapeOverride)
            || (convertedShape.kind.blocksAutomaticConversion
                && candidate.kind != .trailingPunctuation
                && candidate.kind != .wrappingPunctuation
                && !softShapeOverride) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }

        let always = policy.alwaysConvert.contains(converted)
        if always {
            return fixed(baseCandidate, verdict: .switchToConverted, reason: .alwaysConvert, evidence: [.frequent])
        }
        if literal.count == 1,
           FrequentWordLexicon.contains(literal, language: currentCanonical) {
            return fixed(baseCandidate, verdict: .keep, reason: .keepCurrentWord, evidence: [.frequent])
        }
        if confirmed {
            return fixed(baseCandidate, verdict: .switchToConverted, reason: .confirmedByUser, evidence: [.confirmedByUser])
        }
        if adaptiveBias <= -10 {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedLearned, evidence: [.blockedContext])
        }

        let sourceKnown = model.wordLogProbability(literal, language: currentCanonical)
        let sourceExtendedRussian = currentCanonical == "ru" && model.isExtendedRussianWord(literal)
        let targetKnown = targetKnownForShape
        let recentLanguages = contextWords.suffix(4).compactMap(SmartTokenizer.languageHint)
            .map(LanguageCode.canonical)
        let recentEnglishCount = recentLanguages.count(where: { $0 == "en" })
        let recentRussianCount = recentLanguages.count(where: { $0 == "ru" })
        let lastTwoTokensAreEnglish = recentLanguages.suffix(2).count == 2
            && recentLanguages.suffix(2).allSatisfy({ $0 == "en" })
        let frequentEnglishTargetBeatsWeakSource = targetCanonical == "en"
            && targetKnown != nil
            && FrequentWordLexicon.contains(converted, language: targetCanonical)
            && (sourceKnown == nil || (literal.count <= 2 && lastTwoTokensAreEnglish))
            && (!sourceExtendedRussian
                || (recentEnglishCount > 0 && recentEnglishCount >= recentRussianCount))
        let directConsumesLeadingPunctuation = targetCanonical == "ru"
            && targetExtendedRussian
            && candidate.typedRaw.dropFirst(candidate.prefix.count).first.map(Self.isPunctuation) == true
        let englishSourceConfidence: EnglishSourceConfidence? = currentCanonical == "en" && targetCanonical == "ru"
            ? (directConsumesLeadingPunctuation
                ? .unlikely
                : EnglishSourceClassifier.classify(literal, model: model))
            : nil
        let strongScriptMismatch = ScriptMismatchHeuristics.hasStrongMismatch(
            typed: candidate.typedRaw,
            converted: converted,
            targetLanguage: targetLanguage
        )
        let characterAdvantage = model.characterLogProbability(converted, language: targetCanonical)
            - model.characterLogProbability(literal, language: currentCanonical)
        let extendedEnglishTargetBase = currentCanonical == "ru"
            && targetCanonical == "en"
            && targetEnglishTier != nil
            && converted.count >= 4
            && sourceKnown == nil
            && !sourceExtendedRussian
        let strongExtendedEnglishTarget = extendedEnglishTargetBase
            && characterAdvantage >= model.thresholds.englishTargetCharacterAdvantage
        let rankedExtendedEnglishTarget = extendedEnglishTargetBase
            && (model.metadata.formatVersion >= 2 || strongExtendedEnglishTarget)
        let strongExtendedRussianTarget = currentCanonical == "en"
            && targetExtendedRussian
            && sourceKnown == nil
            && englishSourceConfidence == .unlikely
        // Dictionary membership alone does not make both readings equally
        // likely. A frequent target far above every unlisted source spelling
        // wins: `тучею` → `next.`, `ult` → `где`. Common and standard SCOWL
        // words sit just below the frequency list (`herb`), so only rare ones
        // count as rare.
        let sourceSpellingOnly = sourceKnown == nil
            && (sourceExtendedRussian || (currentCanonical == "en" && model.englishSpellingTier(literal) == .rare))
        let frequencyGap = targetKnown.map {
            $0 - model.unlistedWordLogProbabilityBound(language: currentCanonical)
        }
        let frequentTargetOutranksRareSource = literal.count >= 2
            && sourceSpellingOnly
            && (frequencyGap ?? -.infinity) >= Self.rareSourceFrequencyMargin
        // Two known readings (`руку`/`here`, `руки`/`herb`) follow the language of the
        // words just typed: English prose continues in English, Russian in
        // Russian. One previous word is enough when it is commonly followed
        // by the target reading (`come here`).
        let recentTwoLanguages = recentLanguages.suffix(2)
        let previousFollowedByTarget = recentLanguages.last == targetCanonical
            && contextWords.last.flatMap {
                model.followerLogProbability(previous: SmartTokenizer.lexicalCore(of: $0), word: converted, language: targetCanonical)
            }.map { $0 >= Self.followerContinuationFloor } == true
        let contextContinuesInTarget = literal.count >= 2
            && targetKnown != nil
            && ((recentTwoLanguages.count == 2 && recentTwoLanguages.allSatisfy { $0 == targetCanonical })
                || previousFollowedByTarget)
        if literal.count >= 2,
           sourceKnown != nil || sourceExtendedRussian,
           targetKnown != nil || targetExtendedEnglish || targetExtendedRussian,
           !frequentEnglishTargetBeatsWeakSource,
           !frequentTargetOutranksRareSource,
           !contextContinuesInTarget {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
        }
        if literal.count >= 2, englishSourceConfidence == .frequent, !contextContinuesInTarget {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.englishSourceFrequent]
            )
        }
        if literal.count >= 2, englishSourceConfidence == .dictionary, !frequentTargetOutranksRareSource,
           !contextContinuesInTarget {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.englishSourceDictionary]
            )
        }
        if literal.count >= 2, sourceExtendedRussian, !frequentEnglishTargetBeatsWeakSource,
           !frequentTargetOutranksRareSource, !contextContinuesInTarget {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.russianSourceDictionary]
            )
        }
        if directConsumesLeadingPunctuation, strongExtendedRussianTarget {
            return fixed(
                baseCandidate,
                verdict: .switchToConverted,
                reason: .frequentWord,
                evidence: [.russianTargetDictionary, .punctuationPath]
            )
        }
        // A compound is evidence only when the literal hypothesis is not itself a
        // known word. This protects ordinary English prose from productive Russian
        // prefix decompositions that happen to share the same physical keys.
        let compound = sourceKnown == nil
            ? CompoundWordAnalyzer.analyze(converted, language: targetCanonical, model: model)
            : nil
        var evidence: [DecoderEvidence] = []

        var literalScore = Self.lexicalScore(literal, language: currentCanonical, known: sourceKnown, model: model)
        var convertedScore = Self.lexicalScore(converted, language: targetCanonical, known: targetKnown, model: model)
        let currentBeliefScore = languageBelief.score(language: currentCanonical)
        let targetBeliefScore = languageBelief.score(language: targetCanonical)
        literalScore += currentBeliefScore
        convertedScore += targetBeliefScore + adaptiveBias

        if currentCanonical == "en", targetCanonical == "ru",
           sourceKnown == nil, targetKnown == nil,
           strongScriptMismatch, converted.count >= 6,
           characterAdvantage >= model.thresholds.russianOOVEnglishLong {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }
        if let tier = targetEnglishTier, rankedExtendedEnglishTarget {
            // Strong character evidence keeps the exact V3 scoring path. Ranked
            // SCOWL evidence extends that path only for weaker spellings.
            let recovery = strongExtendedEnglishTarget
                ? model.thresholds.englishTargetStrongCharacterContextRecovery
                : Self.englishTargetContextRecovery(tier, thresholds: model.thresholds)
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
                * recovery
        }
        if frequentEnglishTargetBeatsWeakSource {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }
        if strongExtendedRussianTarget {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }
        if contextContinuesInTarget {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }
        if frequentTargetOutranksRareSource, let frequencyGap {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
                + frequencyGap - Self.rareSourceFrequencyMargin
        }

        let attestedTargetOverNonWord = !Self.preservesLayoutLetterPrefix(candidate)
            && sourceKnown == nil
            && !sourceExtendedRussian
            && !(currentCanonical == "en" && model.isExtendedEnglishWord(literal))
            && model.attestedWordLogProbability(converted, language: targetCanonical) != nil
        if sourceKnown != nil { literalScore += 2.2 }
        if englishSourceConfidence == .plausibleOOV {
            literalScore += model.thresholds.englishSourcePlausibleBonus
            evidence.append(.englishSourcePlausible)
        } else if englishSourceConfidence == .unlikely {
            evidence.append(.englishSourceUnlikely)
        }
        if targetKnown != nil {
            convertedScore += 3.0
            evidence.append(.frequent)
        } else if let tier = targetEnglishTier, rankedExtendedEnglishTarget {
            if strongExtendedEnglishTarget {
                convertedScore += model.thresholds.englishTargetStrongCharacterBonus
            } else {
                convertedScore += Self.englishTargetDictionaryBonus(tier, thresholds: model.thresholds)
                convertedScore += min(3, max(-3, characterAdvantage))
                    * model.thresholds.englishTargetCharacterWeight
            }
            evidence.append(.englishTargetDictionary)
        } else if strongExtendedRussianTarget {
            convertedScore += 3.0
            evidence.append(.russianTargetDictionary)
        } else if attestedTargetOverNonWord {
            // A name in use (`<ei` → `Буш`) against typed letters that spell
            // no word in either dictionary.
            convertedScore += 3.0
            evidence.append(targetCanonical == "ru" ? .russianTargetDictionary : .englishTargetDictionary)
        } else {
            evidence.append(.characterModel)
        }

        if let score = model.phraseLogProbability(context: contextWords, candidate: literal, language: currentCanonical) {
            literalScore += max(0, 3.2 + score * 0.45)
        }
        if let score = model.phraseLogProbability(context: contextWords, candidate: converted, language: targetCanonical) {
            convertedScore += max(0, 3.8 + score * 0.45)
            evidence.append(.phraseContext)
        }
        if let compound {
            convertedScore += model.thresholds.compoundBonus + min(4, compound.score * 0.18)
            evidence.append(.compound(segmentLengths: compound.segments.map(\.count)))
        }

        let sourceHint = SmartTokenizer.languageHint(for: literal)
        let targetHint = SmartTokenizer.languageHint(for: converted)
        if sourceHint.map({ LanguageCode.canonical($0) == currentCanonical }) == true { literalScore += 1.2 }
        if targetHint.map({ LanguageCode.canonical($0) == targetCanonical }) == true { convertedScore += 1.2 }
        if candidate.kind == .trailingPunctuation || candidate.kind == .wrappingPunctuation {
            let coreHasLexicalEvidence = targetKnown != nil
                || rankedExtendedEnglishTarget
                || strongExtendedRussianTarget
                || FrequentWordLexicon.contains(converted, language: targetCanonical)
            if coreHasLexicalEvidence {
                // Safe wrappers around real words: `[yt` → `[не`, `{gjnjv)` → `{потом)`.
                convertedScore += 0.35
            } else if Self.preservesLayoutLetterPrefix(candidate) || Self.preservesLayoutLetterSuffix(candidate) {
                // OOV cores must not keep a layout-letter key as punctuation:
                // `[etvjt` → `хуемое`, not `[уемое`; `utjabkmnhfwb.` → `геофильтрацию`.
                convertedScore -= 1.25
            } else {
                convertedScore += 0.35
            }
            if !candidate.suffix.isEmpty,
               Self.preservesTypedSuffix(candidate),
               coreHasLexicalEvidence || !Self.preservesLayoutLetterSuffix(candidate),
               candidate.suffix.allSatisfy({ ".!?".contains($0) }) {
                convertedScore += min(1.5, Double(candidate.suffix.count) * 0.5)
            }
        }
        if capsLock { literalScore += 1.0 }

        let targetProbability = languageBelief.probability(language: targetCanonical)
        let currentProbability = languageBelief.probability(language: currentCanonical)
        var threshold: Double
        if converted.count <= 2 {
            threshold = model.thresholds.short
        } else if targetProbability >= 0.68 {
            threshold = model.thresholds.russianContext
        } else if currentProbability >= 0.68 {
            threshold = model.thresholds.englishContext
        } else {
            threshold = model.thresholds.neutral
        }

        if currentCanonical == "en", targetCanonical == "ru",
           sourceKnown == nil, targetKnown == nil, strongScriptMismatch {
            if currentProbability < 0.62 {
                threshold = min(threshold, model.thresholds.russianOOVNeutral)
            } else if converted.count >= 6 {
                threshold = min(threshold, model.thresholds.russianOOVEnglishLong)
            }
        }

        if converted.count == 1, targetCanonical == "ru" {
            let hasRecentRussianContext = recentLanguages.contains("ru")
            let lastTokenIsEnglish = recentLanguages.last == "en"
            if lastTokenIsEnglish, !hasRecentRussianContext, targetProbability < 0.55 {
                return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
            }
        }
        // A name in use (`Ыфт` → `San`, `Дщы` → `Los`) is attested English
        // text, while its typed letters spell no Russian word.
        let attestedEnglishName = model.attestedWordLogProbability(converted, language: targetCanonical) != nil
            && !sourceExtendedRussian
        if currentCanonical == "ru", targetCanonical == "en",
           sourceKnown == nil, targetKnown == nil, !rankedExtendedEnglishTarget, !attestedEnglishName {
            // Unknown English words can still be clear layout mistakes (афиду →
            // fable). Permit them only when the character model has a strong
            // advantage and the recent language state is not distinctly Russian.
            let characterAdvantage = model.characterLogProbability(converted, language: targetCanonical)
                - model.characterLogProbability(literal, language: currentCanonical)
            if converted.count < 5
                || characterAdvantage < model.thresholds.englishTargetCharacterAdvantage
                || currentProbability >= 0.62 {
                return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
            }
        }

        let margin = convertedScore - literalScore
        let hasLexicalEvidence = targetKnown != nil
            || attestedAcronymPair
            || hyphenatedTargetWord
            || rankedExtendedEnglishTarget
            || strongExtendedRussianTarget
            || compound != nil
            // Two letters are too ambiguous for attestation alone (`tv` reads as
            // the attested `ем` just as `rv` reads as `км`) unless typed with a
            // key no prose uses there (`y/` → `н.`).
            || (attestedTargetOverNonWord
                && (converted.count >= 3 || candidate.typedRaw.contains(where: Self.isUnusualInProse)))
            || (strongScriptMismatch
                && (model.characterLogProbability(converted, language: targetCanonical)
                    >= Self.unlistedTargetCharacterFloor
                    || model.attestedWordLogProbability(converted, language: targetCanonical) != nil))
        let ruleVerdict: LayoutVerdict = margin >= threshold && hasLexicalEvidence
            ? .switchToConverted
            : (sourceKnown != nil || sourceExtendedRussian ? .keep : .undecided)
        // Short plain words, acronyms and typed keys kept with another meaning
        // in the target layout (`[`, `?`) stay with the rules.
        let typedCore = SmartTokenizer.lexicalCore(of: candidate.typedRaw)
        let calibrationFeatures: [String: Double]? = ruleVerdict == .undecided
            && (converted.count >= 3 || (converted.count == 2 && candidate.typedRaw.contains(where: Self.isUnusualInProse)))
            && !(typedCore.count > 1 && typedCore == typedCore.uppercased())
            && !Self.preservesLayoutLetterPrefix(candidate)
            && !(Self.preservesTypedSuffix(candidate) && KeyMapping.convert(candidate.suffix) != candidate.suffix)
            ? Self.calibrationFeatures(
                literal: literal,
                converted: converted,
                typed: candidate.typedRaw,
                currentLanguage: currentCanonical,
                targetLanguage: targetCanonical,
                margin: margin,
                threshold: threshold,
                targetProbability: targetProbability,
                contextWords: contextWords,
                model: model
            )
            : nil
        let calibrated = calibrationFeatures.map { model.thresholds.undecidedCalibration?.accepts($0) == true } == true
        let verdict: LayoutVerdict = calibrated ? .switchToConverted : ruleVerdict
        if verdict == .undecided { evidence.append(.abstained) }
        if calibrated { evidence.append(.calibrated) }
        let reason: AutoConvertDecisionReason
        if verdict == .switchToConverted {
            if calibrated { reason = .calibratedScore }
            else if compound != nil && targetKnown == nil { reason = .compound }
            else if evidence.contains(.phraseContext) { reason = .phraseContext }
            else if rankedExtendedEnglishTarget { reason = .dictionary }
            else if targetKnown != nil || strongExtendedRussianTarget {
                reason = converted.count <= 3 ? .frequentShort : .frequentWord
            }
            else { reason = .characterModel }
        } else {
            reason = verdict == .keep ? .keepCurrentWord : .undecided
        }
        return LayoutDecoderEvaluation(
            decision: AutoConvertDecision(verdict: verdict, reason: reason, candidate: candidate),
            literalScore: literalScore,
            convertedScore: convertedScore,
            threshold: threshold,
            evidence: evidence,
            calibrationFeatures: calibrationFeatures
        )
    }

    private static func calibrationFeatures(
        literal: String,
        converted: String,
        typed: String,
        currentLanguage: String,
        targetLanguage: String,
        margin: Double,
        threshold: Double,
        targetProbability: Double,
        contextWords: [String],
        model: LanguageModelStore
    ) -> [String: Double] {
        func characterRate(_ word: String, _ language: String) -> Double {
            max(-20, model.characterLogProbability(word, language: language) / Double(max(1, word.count)))
        }
        let sourceAttested = model.attestedWordLogProbability(literal, language: currentLanguage)
        let targetAttested = model.attestedWordLogProbability(converted, language: targetLanguage)
        let targetDictionary = targetLanguage == "ru"
            ? model.isExtendedRussianWord(converted)
            : model.isExtendedEnglishWord(converted)
        func flag(_ value: Bool) -> Double { value ? 1 : 0 }
        return [
            "dir": flag(currentLanguage == "en"),
            "margin": margin,
            "threshold": threshold,
            "convLen6": Double(min(converted.count, 6)),
            "pTarget": targetProbability,
            "lastIsTarget": flag(contextWords.last.flatMap(SmartTokenizer.languageHint) == targetLanguage),
            "charConv": characterRate(converted, targetLanguage),
            "charLit": characterRate(literal, currentLanguage),
            "srcAtt": max(-30, sourceAttested ?? -30),
            "tgtAtt": max(-30, targetAttested ?? -30),
            "srcAttested": flag(sourceAttested != nil),
            "tgtAttested": flag(targetAttested != nil),
            "tgtDict": flag(targetDictionary),
            "tgtFreq": flag(model.wordLogProbability(converted, language: targetLanguage) != nil),
            "unusual": flag(typed.contains(where: isUnusualInProse)),
            "capital": flag(typed.first?.isUppercase == true),
        ]
    }

    private static func lexicalScore(
        _ word: String,
        language: String,
        known: Double?,
        model: LanguageModelStore
    ) -> Double {
        let character = 13.0 + model.characterLogProbability(word, language: language)
        guard let known else { return character }
        return character + 7.5 + known * 0.55
    }

    private static func englishTargetDictionaryBonus(
        _ tier: EnglishSpellingTier,
        thresholds: LanguageModelThresholds
    ) -> Double {
        switch tier {
        case .common: thresholds.englishTargetCommonBonus
        case .standard: thresholds.englishTargetStandardBonus
        case .rare: thresholds.englishTargetRareBonus
        }
    }

    private static func englishTargetContextRecovery(
        _ tier: EnglishSpellingTier,
        thresholds: LanguageModelThresholds
    ) -> Double {
        switch tier {
        case .common: thresholds.englishTargetCommonContextRecovery
        case .standard: thresholds.englishTargetStandardContextRecovery
        case .rare: thresholds.englishTargetRareContextRecovery
        }
    }

    private static func fixed(
        _ candidate: AutoConvertCandidate,
        verdict: LayoutVerdict,
        reason: AutoConvertDecisionReason,
        evidence: [DecoderEvidence]
    ) -> LayoutDecoderEvaluation {
        LayoutDecoderEvaluation(
            decision: AutoConvertDecision(verdict: verdict, reason: reason, candidate: candidate),
            literalScore: verdict == .switchToConverted ? 0 : 100,
            convertedScore: verdict == .switchToConverted ? 100 : 0,
            threshold: 0,
            evidence: evidence
        )
    }

    private static func fallback(typed: String, converted: String) -> LayoutDecoderEvaluation {
        let candidate = AutoConvertCandidate(
            typedRaw: typed,
            convertedRaw: converted,
            convertedWord: converted,
            suffix: "",
            kind: .directWord
        )
        return fixed(candidate, verdict: .undecided, reason: .undecided, evidence: [])
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in CharacterSet.punctuationCharacters.contains(scalar) }
    }

    private static func isDecoration(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || $0 == "&"
        }
    }

    private static func trailingDecoration(of text: String) -> String {
        String(text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }

    private static func punctuationComparableCore(of text: String) -> String {
        let withoutPrefix = text.drop(while: { !$0.isLetter && !$0.isNumber })
        return FrequentWordLexicon.normalize(
            String(withoutPrefix.reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
        )
    }

    /// Rank punctuation shapes independently of the word. This disambiguates
    /// physical-key paths such as `&!` -> `?!` and `///` -> `...` without
    /// forcing translation when the user already typed a natural `?!` suffix.
    private static func punctuationSequenceScore(_ suffix: String) -> Int {
        switch suffix {
        case "...": return 10
        case "?!", "!?": return 9
        case "!!", "??": return 8
        case ".", ",", "?", "!", ";", ":": return 6
        default:
            if suffix.contains("&") || suffix.contains("/") || suffix.contains("\\") {
                return -3
            }
            if suffix.contains(",!") || suffix.contains(",?") { return -2 }
            return suffix.allSatisfy { ".!?".contains($0) } ? 4 : 0
        }
    }
}
