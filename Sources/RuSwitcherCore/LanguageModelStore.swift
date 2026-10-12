import Foundation

public struct LanguageModelMetadata: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let modelVersion: String
    public let source: String
    public let sourceRevision: String
    public let license: String
    public let wordCounts: [String: Int]
}

/// Logistic weights over the decoder's own evidence, fitted on FLORES
/// development phrases by `scripts/fit_undecided_calibration.py`. They decide
/// only words that the rules leave undecided.
public struct UndecidedCalibration: Codable, Equatable, Sendable {
    public let features: [String]
    public let mean: [Double]
    public let scale: [Double]
    public let weights: [Double]
    public let bias: Double
    public let threshold: Double

    public func accepts(_ values: [String: Double]) -> Bool {
        guard mean.count == features.count, scale.count == features.count, weights.count == features.count
        else { return false }
        var score = bias
        for (index, name) in features.enumerated() {
            guard let value = values[name], scale[index] > 0 else { return false }
            score += weights[index] * (value - mean[index]) / scale[index]
        }
        return 1 / (1 + exp(-score)) >= threshold
    }
}

public struct LanguageModelThresholds: Codable, Equatable, Sendable {
    public let short: Double
    public let russianContext: Double
    public let neutral: Double
    public let englishContext: Double
    public let russianOOVNeutral: Double
    public let russianOOVEnglishLong: Double
    public let englishSourceCharacterFloor: Double
    public let englishSourcePlausibleBonus: Double
    public let englishTargetCharacterAdvantage: Double
    public let englishTargetCommonBonus: Double
    public let englishTargetStandardBonus: Double
    public let englishTargetRareBonus: Double
    public let englishTargetCharacterWeight: Double
    public let englishTargetStrongCharacterBonus: Double
    public let englishTargetCommonContextRecovery: Double
    public let englishTargetStandardContextRecovery: Double
    public let englishTargetRareContextRecovery: Double
    public let englishTargetStrongCharacterContextRecovery: Double
    public let compoundBonus: Double
    public let confirmedBonus: Double
    public let undecidedCalibration: UndecidedCalibration?

    private enum CodingKeys: String, CodingKey {
        case short, russianContext, neutral, englishContext
        case russianOOVNeutral, russianOOVEnglishLong
        case englishSourceCharacterFloor, englishSourcePlausibleBonus
        case englishTargetCharacterAdvantage
        case englishTargetCommonBonus, englishTargetStandardBonus
        case englishTargetRareBonus, englishTargetCharacterWeight
        case englishTargetStrongCharacterBonus
        case englishTargetCommonContextRecovery
        case englishTargetStandardContextRecovery
        case englishTargetRareContextRecovery
        case englishTargetStrongCharacterContextRecovery
        case compoundBonus, confirmedBonus, undecidedCalibration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        short = try values.decode(Double.self, forKey: .short)
        russianContext = try values.decode(Double.self, forKey: .russianContext)
        neutral = try values.decode(Double.self, forKey: .neutral)
        englishContext = try values.decode(Double.self, forKey: .englishContext)
        russianOOVNeutral = try values.decode(Double.self, forKey: .russianOOVNeutral)
        russianOOVEnglishLong = try values.decode(Double.self, forKey: .russianOOVEnglishLong)
        englishSourceCharacterFloor = try values.decode(Double.self, forKey: .englishSourceCharacterFloor)
        englishSourcePlausibleBonus = try values.decode(Double.self, forKey: .englishSourcePlausibleBonus)
        englishTargetCharacterAdvantage = try values.decode(Double.self, forKey: .englishTargetCharacterAdvantage)
        // Model-format 1 had a flat SCOWL set. Defaults keep old artifacts
        // readable while format 2 stores calibrated tier weights explicitly.
        englishTargetCommonBonus = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetCommonBonus
        ) ?? 3.1
        englishTargetStandardBonus = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetStandardBonus
        ) ?? 2.5
        englishTargetRareBonus = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetRareBonus
        ) ?? 1.8
        englishTargetCharacterWeight = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetCharacterWeight
        ) ?? 0.35
        englishTargetStrongCharacterBonus = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetStrongCharacterBonus
        ) ?? 3.0
        englishTargetCommonContextRecovery = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetCommonContextRecovery
        ) ?? 1.0
        englishTargetStandardContextRecovery = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetStandardContextRecovery
        ) ?? 0.7
        englishTargetRareContextRecovery = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetRareContextRecovery
        ) ?? 0.35
        englishTargetStrongCharacterContextRecovery = try values.decodeIfPresent(
            Double.self,
            forKey: .englishTargetStrongCharacterContextRecovery
        ) ?? 1.0
        compoundBonus = try values.decode(Double.self, forKey: .compoundBonus)
        confirmedBonus = try values.decode(Double.self, forKey: .confirmedBonus)
        undecidedCalibration = try values.decodeIfPresent(UndecidedCalibration.self, forKey: .undecidedCalibration)
    }
}

/// SCOWL sizes are confidence tiers, not word-specific overrides. Higher tiers
/// contain progressively more common spellings from the same pinned source.
public enum EnglishSpellingTier: Int, Codable, Comparable, Sendable {
    case rare = 1       // SCOWL 60 only
    case standard = 2   // SCOWL 50
    case common = 3     // SCOWL 35

    public static func < (lhs: EnglishSpellingTier, rhs: EnglishSpellingTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum LanguageModelError: Error, Equatable {
    case missingResource
    case invalidHeader
    case unsupportedVersion(Int)
    case invalidDirectory
    case checksumMismatch
    case missingSection(Int)
    case invalidSection(Int)
}

/// Immutable, memory-mapped model. Score tables are read in place
/// (`ModelScoreTable`); JSON is left only for small settings sections.
public final class LanguageModelStore: @unchecked Sendable {
    private enum Section: UInt16, CaseIterable {
        case metadata = 1
        case ruWords = 2
        case enWords = 3
        case ruCharacters = 4
        case enCharacters = 5
        case ruBigrams = 6
        case enBigrams = 7
        case ruTrigrams = 8
        case enTrigrams = 9
        case productive = 10
        case thresholds = 11
        case extendedEnglish = 12
        case extendedRussian = 13
        case ruFollowers = 14
        case enFollowers = 15
        case ruAttested = 16
        case enAttested = 17
    }

    public static var bundledResourceURL: URL? {
        Bundle.main.url(forResource: "language-model-v1", withExtension: "bin")
            ?? Bundle.module.url(forResource: "language-model-v1", withExtension: "bin")
    }

    public static let bundled: LanguageModelStore? = {
        guard let url = bundledResourceURL else {
            return nil
        }
        return try? LanguageModelStore(contentsOf: url)
    }()

    public let metadata: LanguageModelMetadata
    public let thresholds: LanguageModelThresholds
    public let productiveRussianParts: Set<String>
    public let productiveRussianSuffixes: Set<String>
    private let extendedEnglishTiers: ModelScoreTable
    private let extendedRussianWords: RussianSpellingBloom

    private let words: [String: ModelScoreTable]
    private let rarestWordLogProbability: [String: Double]
    private let characters: [String: ModelScoreTable]
    private let bigrams: [String: ModelScoreTable]
    private let trigrams: [String: ModelScoreTable]
    private let followers: [String: ModelScoreTable]
    private let attestedWords: [String: ModelScoreTable]

    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard data.count >= 20,
              String(data: data.prefix(4), encoding: .ascii) == "RSLM" else {
            throw LanguageModelError.invalidHeader
        }
        let version = Int(Self.readUInt16(data, at: 4))
        guard version == 3 else {
            throw LanguageModelError.unsupportedVersion(version)
        }
        let count = Int(Self.readUInt16(data, at: 6))
        let payloadLength = Int(Self.readUInt32(data, at: 8))
        let checksum = Self.readUInt64(data, at: 12)
        let directoryEnd = 20 + count * 12
        guard count > 0, directoryEnd <= data.count, data.count - directoryEnd == payloadLength else {
            throw LanguageModelError.invalidDirectory
        }
        guard Self.fnv1a64(data, from: directoryEnd) == checksum else { throw LanguageModelError.checksumMismatch }

        var sectionRanges: [Section: Range<Int>] = [:]
        for index in 0..<count {
            let base = 20 + index * 12
            guard let kind = Section(rawValue: Self.readUInt16(data, at: base)) else { continue }
            let offset = Int(Self.readUInt32(data, at: base + 4))
            let length = Int(Self.readUInt32(data, at: base + 8))
            guard offset >= 0, length >= 0, offset + length <= payloadLength else {
                throw LanguageModelError.invalidDirectory
            }
            let start = directoryEnd + offset
            sectionRanges[kind] = start..<(start + length)
        }

        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, section: Section) throws -> T {
            guard let range = sectionRanges[section] else {
                throw LanguageModelError.missingSection(Int(section.rawValue))
            }
            do { return try decoder.decode(type, from: data.subdata(in: range)) }
            catch { throw LanguageModelError.invalidSection(Int(section.rawValue)) }
        }
        func table(_ section: Section) throws -> ModelScoreTable {
            guard let range = sectionRanges[section] else {
                throw LanguageModelError.missingSection(Int(section.rawValue))
            }
            return try ModelScoreTable(storage: data, range: range, section: Int(section.rawValue))
        }
        // Optional since model 2026.10-v3.2: older models simply have no
        // next-word evidence for ambiguous pairs.
        func optionalTable(_ section: Section) throws -> ModelScoreTable {
            sectionRanges[section] == nil ? .empty : try table(section)
        }

        metadata = try decode(LanguageModelMetadata.self, section: .metadata)
        thresholds = try decode(LanguageModelThresholds.self, section: .thresholds)
        let productive: [String] = try decode([String].self, section: .productive)
        productiveRussianParts = Set(productive.filter { !$0.hasPrefix("-") })
        productiveRussianSuffixes = Set(productive.compactMap { value in
            value.hasPrefix("-") ? String(value.dropFirst()) : nil
        })
        words = ["ru": try table(.ruWords), "en": try table(.enWords)]
        rarestWordLogProbability = words.mapValues { $0.minimumValue() ?? 0 }
        characters = ["ru": try table(.ruCharacters), "en": try table(.enCharacters)]
        bigrams = ["ru": try table(.ruBigrams), "en": try table(.enBigrams)]
        trigrams = ["ru": try table(.ruTrigrams), "en": try table(.enTrigrams)]
        extendedEnglishTiers = try table(.extendedEnglish)
        followers = ["ru": try optionalTable(.ruFollowers), "en": try optionalTable(.enFollowers)]
        attestedWords = ["ru": try optionalTable(.ruAttested), "en": try optionalTable(.enAttested)]
        guard let russianBloomRange = sectionRanges[.extendedRussian] else {
            throw LanguageModelError.missingSection(Int(Section.extendedRussian.rawValue))
        }
        extendedRussianWords = try RussianSpellingBloom(storage: data, range: russianBloomRange)
    }

    public func contains(_ word: String, language: String) -> Bool {
        wordLogProbability(word, language: language) != nil
    }

    public func isExtendedEnglishWord(_ word: String) -> Bool {
        englishSpellingTier(word) != nil
    }

    public func englishSpellingTier(_ word: String) -> EnglishSpellingTier? {
        extendedEnglishTiers.value(for: Self.normalize(word)).flatMap { EnglishSpellingTier(rawValue: Int($0)) }
    }

    public func trainingExtendedEnglishWords(limit: Int? = nil) -> [String] {
        let words = extendedEnglishTiers.entries().map(\.key)
        guard let limit else { return words }
        return Array(words.prefix(max(0, limit)))
    }

    public func trainingExtendedEnglishWords(
        minimumTier: EnglishSpellingTier,
        limit: Int? = nil
    ) -> [String] {
        let values = extendedEnglishTiers.entries().compactMap { entry in
            Int(entry.value) >= minimumTier.rawValue ? entry.key : nil
        }
        guard let limit else { return values }
        return Array(values.prefix(max(0, limit)))
    }

    public func isExtendedRussianWord(_ word: String) -> Bool {
        extendedRussianWords.contains(Self.normalize(word))
    }

    /// A correctly spelled word missing from the frequency table is rarer than
    /// every listed word, so its log-probability is at most this bound.
    public func unlistedWordLogProbabilityBound(language: String) -> Double {
        rarestWordLogProbability[Self.canonical(language)] ?? 0
    }

    public func wordLogProbability(_ word: String, language: String) -> Double? {
        words[Self.canonical(language)]?.value(for: Self.normalize(word))
    }

    /// Deterministic frequency order used by offline quality gates. The app
    /// itself never enumerates the model in the event-tap path.
    public func trainingWords(language: String, limit: Int? = nil) -> [String] {
        let ranked = (words[Self.canonical(language)]?.entries() ?? [])
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .map(\.key)
        guard let limit else { return ranked }
        return Array(ranked.prefix(max(0, limit)))
    }

    public func characterLogProbability(_ word: String, language: String) -> Double {
        let normalized = Self.normalize(word)
        guard !normalized.isEmpty, let model = characters[Self.canonical(language)] else { return -16 }
        let padded = Array("^" + normalized + "$")
        var total = 0.0
        var count = 0
        for size in 2...5 where padded.count >= size {
            for index in 0...(padded.count - size) {
                total += model.value(for: String(padded[index..<(index + size)])) ?? -16
                count += 1
            }
        }
        return count == 0 ? -16 : total / Double(count)
    }

    /// The listed frequency, or else a Tatoeba-attested one placed below every
    /// listed word. Spelling forms that conversational text never uses have none.
    /// An English possessive is attested through its base (`country's`, `Nadal's`).
    public func attestedWordLogProbability(_ word: String, language: String) -> Double? {
        let normalized = Self.normalize(word)
        let canonical = Self.canonical(language)
        if let value = words[canonical]?.value(for: normalized) ?? attestedWords[canonical]?.value(for: normalized) {
            return value
        }
        guard canonical == "en", normalized.count > 3, normalized.hasSuffix("'s") else { return nil }
        let base = String(normalized.dropLast(2))
        return words[canonical]?.value(for: base) ?? attestedWords[canonical]?.value(for: base)
    }

    /// ln P(word | previous) from conversational text, present only for words
    /// whose keys also spell a frequent word in the other layout.
    public func followerLogProbability(previous: String, word: String, language: String) -> Double? {
        followers[Self.canonical(language)]?.value(for: [Self.normalize(previous), Self.normalize(word)].joined(separator: "\u{1f}"))
    }

    public func phraseLogProbability(context: [String], candidate: String, language: String) -> Double? {
        let lang = Self.canonical(language)
        let normalizedCandidate = Self.normalize(candidate)
        let normalizedContext = context.map(Self.normalize).filter { !$0.isEmpty }
        if normalizedContext.count >= 2 {
            let key = (Array(normalizedContext.suffix(2)) + [normalizedCandidate]).joined(separator: "\u{1f}")
            if let score = trigrams[lang]?.value(for: key) { return score }
        }
        if let previous = normalizedContext.last {
            return bigrams[lang]?.value(for: [previous, normalizedCandidate].joined(separator: "\u{1f}"))
        }
        return nil
    }

    private static func canonical(_ language: String) -> String {
        LanguageCode.canonical(language)
    }

    private static func normalize(_ text: String) -> String {
        FrequentWordLexicon.normalize(text)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }

    private static func fnv1a64(_ data: Data, from start: Int) -> UInt64 {
        data.withUnsafeBytes { raw in
            var value: UInt64 = 0xcbf29ce484222325
            for byte in raw[start...] {
                value ^= UInt64(byte)
                value = value &* 0x100000001b3
            }
            return value
        }
    }
}
