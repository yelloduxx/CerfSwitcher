import Foundation

/// Words the user types often that no dictionary lists. A spelling becomes a
/// personal word after enough separate occasions; the decoder then treats it
/// like the rarest listed word of that language. Nothing here is ever logged.
public struct PersonalLexicon: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var count: Int
        public var lastSeen: Date
        public var promoted: Bool
    }

    public static let promotionCount = 3
    /// Repeats inside one burst (`ок ок ок`) are one occasion.
    public static let occasionInterval: TimeInterval = 10 * 60
    public static let candidateLimit = 4_000
    public static let promotedLimit = 2_000
    public static let minimumLength = 2
    public static let maximumLength = 32

    public var version: Int
    public var entries: [String: Entry]

    public init(version: Int = 1, entries: [String: Entry] = [:]) {
        self.version = version
        self.entries = entries
    }

    public func promotedWords(language: String) -> Set<String> {
        let prefix = Self.prefix(language)
        return Set(entries.compactMap { key, entry in
            entry.promoted && key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        })
    }

    public var promotedWordsByLanguage: [String: Set<String>] {
        ["ru": promotedWords(language: "ru"), "en": promotedWords(language: "en")]
    }

    /// The spelling a completed token contributes, or nil when the token is
    /// not a plain word of the typed language or a dictionary already lists it.
    public static func eligibleWord(typed: String, language: String, model: LanguageModelStore) -> String? {
        let canonical = LanguageCode.canonical(language)
        guard SmartTokenizer.shape(of: typed).kind == .lexical else { return nil }
        let word = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: typed))
        guard (minimumLength...maximumLength).contains(word.count),
              word.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }),
              word.first?.isLetter == true, word.last?.isLetter == true,
              !SmartTokenizer.isAllUppercaseWord(typed),
              SmartTokenizer.languageHint(for: word).map(LanguageCode.canonical) == canonical,
              model.wordLogProbability(word, language: canonical) == nil
        else { return nil }
        // A spelling the character model prefers in the other layout is a
        // layout mistake the decoder missed, not a word: `jr` for `ок`.
        let converted = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: KeyMapping.convert(word)))
        let other = canonical == "ru" ? "en" : "ru"
        guard !converted.isEmpty,
              model.characterLogProbability(word, language: canonical) / Double(word.count)
                > model.characterLogProbability(converted, language: other) / Double(converted.count)
        else { return nil }
        return word
    }

    /// Records one sighting. Returns true when the set of promoted words changed.
    @discardableResult
    public mutating func observe(word: String, language: String, at date: Date = Date()) -> Bool {
        let key = Self.key(word, language)
        if var entry = entries[key] {
            guard date.timeIntervalSince(entry.lastSeen) >= Self.occasionInterval else { return false }
            entry.count += 1
            entry.lastSeen = date
            let promoting = !entry.promoted && entry.count >= Self.promotionCount
            if promoting {
                entry.promoted = true
                evictPromoted(keeping: date)
            }
            entries[key] = entry
            return promoting
        }
        entries[key] = Entry(count: 1, lastSeen: date, promoted: false)
        evictCandidates()
        return false
    }

    /// The user converted this spelling by hand, so it is not their word.
    @discardableResult
    public mutating func remove(word: String, language: String) -> Bool {
        let removed = entries.removeValue(forKey: Self.key(word, language))
        return removed?.promoted == true
    }

    private mutating func evictCandidates() {
        let candidates = entries.filter { !$0.value.promoted }
        guard candidates.count > Self.candidateLimit else { return }
        let excess = candidates.count - Self.candidateLimit
        for (key, _) in candidates.sorted(by: Self.weakerFirst).prefix(excess) {
            entries.removeValue(forKey: key)
        }
    }

    private mutating func evictPromoted(keeping date: Date) {
        let promoted = entries.filter(\.value.promoted)
        guard promoted.count >= Self.promotedLimit else { return }
        for (key, _) in promoted.sorted(by: Self.weakerFirst).prefix(promoted.count - Self.promotedLimit + 1) {
            entries.removeValue(forKey: key)
        }
    }

    private static func weakerFirst(_ lhs: (key: String, value: Entry), _ rhs: (key: String, value: Entry)) -> Bool {
        if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
        return lhs.value.lastSeen < rhs.value.lastSeen
    }

    private static func prefix(_ language: String) -> String {
        LanguageCode.canonical(language) + "\u{1f}"
    }

    private static func key(_ word: String, _ language: String) -> String {
        prefix(language) + FrequentWordLexicon.normalize(word)
    }
}
