import Foundation

/// Words the user lists explicitly: brands, names, tech terms, slang. The
/// decoder reads them the same way as personal words, as the rarest listed
/// word of the language their alphabet belongs to. Nothing here is logged.
public struct UserDictionary: Equatable, Sendable {
    public static let maximumWordLength = 64
    public static let maximumWordCount = 20_000
    static let minimumLetterCount = 2

    public struct Report: Equatable, Sendable {
        public var added = 0
        public var duplicates = 0
        public var invalid = 0
        public var overLimit = 0

        public init(added: Int = 0, duplicates: Int = 0, invalid: Int = 0, overLimit: Int = 0) {
            self.added = added
            self.duplicates = duplicates
            self.invalid = invalid
            self.overLimit = overLimit
        }

        public var skipped: Int { duplicates + invalid + overLimit }
    }

    /// Spellings as the user wrote them, in the order they were added, unique
    /// by their normalized form.
    public private(set) var words: [String] = []
    private var keys: Set<String> = []

    /// Rebuilds a dictionary from stored spellings, dropping any that no
    /// longer pass validation.
    public init(words: [String] = []) {
        add(words)
    }

    public func contains(_ word: String) -> Bool {
        keys.contains(FrequentWordLexicon.normalize(word))
    }

    public var wordsByLanguage: [String: Set<String>] {
        var result: [String: Set<String>] = ["ru": [], "en": []]
        for word in words {
            guard let language = Self.language(of: word) else { continue }
            result[language, default: []].insert(FrequentWordLexicon.normalize(word))
        }
        return result
    }

    /// Adds every word of pasted text or a file: one per line, or separated
    /// by commas, semicolons or whitespace.
    @discardableResult
    public mutating func add(text: String) -> Report {
        add(Self.tokens(in: text))
    }

    @discardableResult
    public mutating func add(_ candidates: [String]) -> Report {
        var report = Report()
        for candidate in candidates {
            guard let word = Self.word(from: candidate) else {
                report.invalid += 1
                continue
            }
            let key = FrequentWordLexicon.normalize(word)
            if keys.contains(key) {
                report.duplicates += 1
            } else if words.count >= Self.maximumWordCount {
                report.overLimit += 1
            } else {
                keys.insert(key)
                words.append(word)
                report.added += 1
            }
        }
        return report
    }

    /// Removes entries by spelling, ignoring case.
    public mutating func remove(_ spellings: some Sequence<String>) {
        let removed = Set(spellings.map(FrequentWordLexicon.normalize))
        words.removeAll { removed.contains(FrequentWordLexicon.normalize($0)) }
        keys.subtract(removed)
    }

    /// One word per line, the same shape `add(text:)` reads back.
    public var exportedText: String {
        words.isEmpty ? "" : words.joined(separator: "\n") + "\n"
    }

    /// Text of an imported file: UTF-16 with a byte-order mark, UTF-8, or
    /// otherwise Windows-1251, the usual encoding of Russian CSV exports.
    public static func decodeFile(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251)
    }

    public static func tokens(in text: String) -> [String] {
        text.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// The entry a raw token contributes: its core without quotes or trailing
    /// punctuation, made only of Latin or only of Cyrillic letters with inner
    /// hyphens or apostrophes. URLs, emails, numbers and mixed scripts are not
    /// words; capitals anywhere are fine (`GitHub`, `NASA`).
    public static func word(from raw: String) -> String? {
        let word = SmartTokenizer.lexicalCore(of: raw.precomposedStringWithCanonicalMapping)
        guard word.count <= maximumWordLength,
              word.first?.isLetter == true, word.last?.isLetter == true,
              word.allSatisfy({ $0.isLetter || innerMarks.contains($0) }),
              word.filter(\.isLetter).count >= minimumLetterCount,
              language(of: word) != nil
        else { return nil }
        return word
    }

    /// `en` when every letter is basic Latin, `ru` when every letter is Cyrillic.
    public static func language(of word: String) -> String? {
        var latin = false
        var cyrillic = false
        for scalar in word.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A: latin = true
            case 0x0400...0x04FF: cyrillic = true
            default: return nil
            }
        }
        if latin == cyrillic { return nil }
        return latin ? "en" : "ru"
    }

    private static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    private static let innerMarks: Set<Character> = ["-", "'", "’"]
}
