import Foundation

public enum AutoConvertCandidateGenerator {

    public static func candidates(typed: String, converted: String) -> [AutoConvertCandidate] {
        let directKind: AutoConvertCandidate.Kind = typed.last.map(isTrailingPunctuation) == true
            ? .layoutLetterTail
            : .directWord
        var result = [
            AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: converted,
                suffix: "",
                kind: directKind
            )
        ]

        let shape = SmartTokenizer.shape(of: typed)
        // Every prefix length is a reading: `[,eath_` is `[` + `буфер` + `_`,
        // because the comma key inside the wrapper is the letter `б`.
        let typedCharacters = Array(typed)
        let prefixCounts = shape.lexicalCore.isEmpty ? 0..<0 : 1..<(shape.prefix.count + 1)
        for prefixCount in prefixCounts {
            let prefix = String(typedCharacters.prefix(prefixCount))
            let remainder = Array(typedCharacters.dropFirst(prefixCount))
            let maximumPreservedSuffix = min(3, remainder.count)
            for suffixLength in 0...maximumPreservedSuffix {
                let suffixCharacters = remainder.suffix(suffixLength)
                guard suffixLength == 0 || suffixCharacters.allSatisfy(isTrailingPunctuation) else {
                    continue
                }
                guard !suffixCharacters.contains(where: isOpeningBracket) else { continue }
                let coreCharacters = remainder.dropLast(suffixLength)
                guard !coreCharacters.isEmpty else { continue }
                let candidate = AutoConvertCandidate(
                    typedRaw: typed,
                    convertedRaw: converted,
                    prefix: prefix,
                    convertedWord: KeyMapping.convert(String(coreCharacters)),
                    suffix: String(suffixCharacters),
                    kind: .wrappingPunctuation
                )
                if !result.contains(candidate) { result.append(candidate) }
                let translatedSuffix = KeyMapping.convert(String(suffixCharacters))
                if translatedSuffix != String(suffixCharacters),
                   translatedSuffix.allSatisfy(isTrailingPunctuation) {
                    let translatedCandidate = AutoConvertCandidate(
                        typedRaw: typed,
                        convertedRaw: converted,
                        prefix: prefix,
                        convertedWord: KeyMapping.convert(String(coreCharacters)),
                        suffix: translatedSuffix,
                        kind: .wrappingPunctuation
                    )
                    if !result.contains(translatedCandidate) { result.append(translatedCandidate) }
                }
            }
        }

        let typedChars = Array(typed)
        let convertedChars = Array(converted)
        let maxSuffix = min(3, typedChars.count, convertedChars.count)
        guard maxSuffix > 0 else { return result }

        for suffixLength in 1...maxSuffix {
            let suffixChars = typedChars.suffix(suffixLength)
            guard suffixChars.allSatisfy(isTrailingPunctuation) else { continue }
            guard !suffixChars.contains(where: isOpeningBracket) else { continue }
            let convertedWordChars = convertedChars.dropLast(suffixLength)
            guard !convertedWordChars.isEmpty else { continue }
            let suffix = String(suffixChars)
            result.append(
                AutoConvertCandidate(
                    typedRaw: typed,
                    convertedRaw: converted,
                    convertedWord: String(convertedWordChars),
                    suffix: suffix,
                    kind: .trailingPunctuation
                )
            )
        }

        // In the reverse RU→EN direction a Cyrillic letter may live on an
        // English punctuation key: гыуб → use,. Treat punctuation produced only
        // after conversion as a suffix candidate too.
        for suffixLength in 1...maxSuffix {
            let convertedSuffix = convertedChars.suffix(suffixLength)
            guard convertedSuffix.allSatisfy(isTrailingPunctuation) else { continue }
            let convertedWordChars = convertedChars.dropLast(suffixLength)
            guard !convertedWordChars.isEmpty else { continue }
            let candidate = AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: String(convertedWordChars),
                suffix: String(convertedSuffix),
                kind: .trailingPunctuation
            )
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    /// An opening bracket never ends a word, so its key is the target-layout
    /// letter there: `b[` -> `их`, `'nb[` -> `этих`. A closing bracket may end
    /// the last word of a bracketed span (`ghfdbkmysq]` -> `правильный]`).
    private static func isOpeningBracket(_ character: Character) -> Bool {
        character == "[" || character == "{"
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || $0 == "&"
        }
    }

    public static func bestCandidate(
        typed: String,
        converted: String,
        targetLanguage: String,
        isValidWord: (String, String) -> Bool
    ) -> AutoConvertCandidate? {
        candidates(typed: typed, converted: converted)
            .max { lhs, rhs in
                score(lhs, targetLanguage: targetLanguage, isValidWord: isValidWord)
                    < score(rhs, targetLanguage: targetLanguage, isValidWord: isValidWord)
            }
    }

    private static func score(
        _ candidate: AutoConvertCandidate,
        targetLanguage: String,
        isValidWord: (String, String) -> Bool
    ) -> Int {
        let word = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        if isValidWord(word, targetLanguage) || FrequentWordLexicon.contains(word, language: targetLanguage) {
            return 10_000 + word.count
        }
        if ScriptMismatchHeuristics.hasStrongMismatch(
            typed: candidate.typedRaw,
            converted: word,
            targetLanguage: targetLanguage
        ) {
            return 1_000 + word.count
        }
        return word.count
    }
}
