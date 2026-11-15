import Foundation

public enum PersonalDataArchiveError: Error, Equatable {
    case fileTooLarge
    case invalidFormat
    case unsupportedVersion(Int)
    case invalidSection(String)
}

/// A complete personal-data replacement, never a merge or a defaults-domain dump.
/// Dates use JSONEncoder's numeric seconds since 2001, preserving subsecond data.
public struct PersonalDataArchive: Equatable, Sendable {
    public static let formatName = "CerfSwitcherPersonalData"
    public static let currentFormatVersion = 1
    public static let maximumFileSize = 16 * 1_024 * 1_024
    public static let maximumExceptionCount = 20_000
    public static let maximumAppCount = 2_000

    public struct Payload: Equatable, Sendable {
        public let adaptiveRules: AdaptiveRuleBook
        public let personalLexicon: PersonalLexicon
        public let userDictionary: [String]
        public let alwaysConvertWords: [String]
        public let deniedWords: [String]
        public let deniedAppsAdded: [String]
        public let deniedAppsRemoved: [String]

        public init(adaptiveRules: AdaptiveRuleBook, personalLexicon: PersonalLexicon,
                    userDictionary: [String], alwaysConvertWords: [String], deniedWords: [String],
                    deniedAppsAdded: [String], deniedAppsRemoved: [String]) throws {
            try PersonalDataArchive.validateAdaptiveRules(adaptiveRules)
            try PersonalDataArchive.validatePersonalLexicon(personalLexicon)
            try PersonalDataArchive.validateUserDictionary(userDictionary)
            try PersonalDataArchive.validateStrings(alwaysConvertWords, limit: maximumExceptionCount,
                                                    section: "alwaysConvertWords")
            try PersonalDataArchive.validateStrings(deniedWords, limit: maximumExceptionCount, section: "deniedWords")
            try PersonalDataArchive.validateStrings(deniedAppsAdded, limit: maximumAppCount, section: "deniedAppsAdded")
            try PersonalDataArchive.validateStrings(deniedAppsRemoved, limit: maximumAppCount, section: "deniedAppsRemoved")
            guard (deniedAppsAdded + deniedAppsRemoved).allSatisfy({ !$0.contains(where: \.isWhitespace) }) else {
                throw PersonalDataArchiveError.invalidSection("deniedApps")
            }
            guard Set(deniedAppsAdded).isDisjoint(with: deniedAppsRemoved) else {
                throw PersonalDataArchiveError.invalidSection("deniedAppsRemoved")
            }
            self.adaptiveRules = adaptiveRules
            self.personalLexicon = personalLexicon
            self.userDictionary = userDictionary
            self.alwaysConvertWords = alwaysConvertWords
            self.deniedWords = deniedWords
            self.deniedAppsAdded = deniedAppsAdded
            self.deniedAppsRemoved = deniedAppsRemoved
        }
    }

    public let payload: Payload
    public let exportedAt: Date

    public init(payload: Payload, exportedAt: Date = Date()) throws {
        guard Self.validDate(exportedAt) else { throw PersonalDataArchiveError.invalidSection("exportedAt") }
        self.payload = payload
        self.exportedAt = exportedAt
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Wire(self))
        guard data.count <= Self.maximumFileSize else { throw PersonalDataArchiveError.fileTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> PersonalDataArchive {
        guard data.count <= maximumFileSize else { throw PersonalDataArchiveError.fileTooLarge }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw PersonalDataArchiveError.invalidFormat }
        guard wire.format == formatName else { throw PersonalDataArchiveError.invalidFormat }
        guard wire.formatVersion == currentFormatVersion else {
            throw PersonalDataArchiveError.unsupportedVersion(wire.formatVersion)
        }
        // Validate raw rules before AdaptiveRuleBook can migrate or discard any.
        guard wire.adaptiveRules.modelVersion == 8,
              wire.adaptiveRules.rules.count <= LearnedCorrectionsArchive.maximumRuleCount else {
            throw PersonalDataArchiveError.invalidSection("adaptiveRules")
        }
        let rules = try wire.adaptiveRules.rules.map { try $0.validated() }
        let payload = try Payload(
            adaptiveRules: AdaptiveRuleBook(rules: rules, modelVersion: wire.adaptiveRules.modelVersion),
            personalLexicon: wire.personalLexicon, userDictionary: wire.userDictionary,
            alwaysConvertWords: wire.alwaysConvertWords, deniedWords: wire.deniedWords,
            deniedAppsAdded: wire.deniedAppsAdded, deniedAppsRemoved: wire.deniedAppsRemoved
        )
        return try PersonalDataArchive(payload: payload, exportedAt: wire.exportedAt)
    }

    public static func validateAdaptiveRules(_ book: AdaptiveRuleBook) throws {
        guard book.modelVersion == 8, book.rules.count <= LearnedCorrectionsArchive.maximumRuleCount else {
            throw PersonalDataArchiveError.invalidSection("adaptiveRules")
        }
        for rule in book.rules { _ = try RawRule(rule).validated() }
    }

    public static func validatePersonalLexicon(_ lexicon: PersonalLexicon) throws {
        guard lexicon.version == 1,
              lexicon.entries.count <= PersonalLexicon.candidateLimit + PersonalLexicon.promotedLimit else {
            throw PersonalDataArchiveError.invalidSection("personalLexicon")
        }
        var promoted = 0
        for (key, entry) in lexicon.entries {
            let parts = key.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PersonalDataArchiveError.invalidSection("personalLexicon") }
            let language = String(parts[0]), word = String(parts[1])
            guard ["ru", "en"].contains(language),
                  (PersonalLexicon.minimumLength...PersonalLexicon.maximumLength).contains(word.count),
                  word == FrequentWordLexicon.normalize(word),
                  UserDictionary.word(from: word) == word, UserDictionary.language(of: word) == language,
                  word.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }),
                  (1...LearningCounter.maximum).contains(entry.count), validDate(entry.lastSeen),
                  entry.promoted == (entry.count >= PersonalLexicon.promotionCount) else {
                throw PersonalDataArchiveError.invalidSection("personalLexicon")
            }
            if entry.promoted { promoted += 1 }
        }
        guard promoted <= PersonalLexicon.promotedLimit,
              lexicon.entries.count - promoted <= PersonalLexicon.candidateLimit else {
            throw PersonalDataArchiveError.invalidSection("personalLexicon")
        }
    }

    public static func validateUserDictionary(_ words: [String]) throws {
        guard words.count <= UserDictionary.maximumWordCount,
              words.allSatisfy({ UserDictionary.word(from: $0) == $0 }),
              Set(words.map(FrequentWordLexicon.normalize)).count == words.count else {
            throw PersonalDataArchiveError.invalidSection("userDictionary")
        }
    }

    private static func validateStrings(_ values: [String], limit: Int, section: String) throws {
        guard values.count <= limit,
              values.allSatisfy({ validString($0) && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw PersonalDataArchiveError.invalidSection(section)
        }
    }

    private static func validString(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 256
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800...253_402_300_799).contains(seconds)
    }

    private struct RawRule: Codable {
        let original: String
        let converted: String
        let appBundleID: String?
        let positiveCount: Int
        let negativeCount: Int
        let confirmed: Bool
        let applicationException: Bool
        let lastUsed: Date

        init(_ rule: AdaptiveRule) {
            original = rule.original; converted = rule.converted; appBundleID = rule.appBundleID
            positiveCount = rule.positiveCount; negativeCount = rule.negativeCount
            confirmed = rule.confirmed; applicationException = rule.applicationException; lastUsed = rule.lastUsed
        }

        func validated() throws -> AdaptiveRule {
            guard [original, converted].allSatisfy({
                validString($0) && $0 == FrequentWordLexicon.normalize($0) && $0.count(where: \.isLetter) >= 2
            }), (0...LearningCounter.maximum).contains(positiveCount), (0...LearningCounter.maximum).contains(negativeCount),
                  appBundleID.map({ validString($0) && !$0.contains(where: \.isWhitespace) }) ?? true,
                  !applicationException || appBundleID != nil, validDate(lastUsed) else {
                throw PersonalDataArchiveError.invalidSection("adaptiveRules")
            }
            return AdaptiveRule(original: original, converted: converted, appBundleID: appBundleID,
                                positiveCount: positiveCount, negativeCount: negativeCount,
                                confirmed: confirmed, applicationException: applicationException, lastUsed: lastUsed)
        }
    }

    private struct RawBook: Codable {
        let modelVersion: Int
        let rules: [RawRule]
    }

    private struct Wire: Codable {
        let format: String
        let formatVersion: Int
        let exportedAt: Date
        let adaptiveRules: RawBook
        let personalLexicon: PersonalLexicon
        let userDictionary: [String]
        let alwaysConvertWords: [String]
        let deniedWords: [String]
        let deniedAppsAdded: [String]
        let deniedAppsRemoved: [String]

        init(_ archive: PersonalDataArchive) {
            let payload = archive.payload
            format = PersonalDataArchive.formatName
            formatVersion = PersonalDataArchive.currentFormatVersion
            exportedAt = archive.exportedAt
            adaptiveRules = RawBook(modelVersion: payload.adaptiveRules.modelVersion,
                                   rules: payload.adaptiveRules.rules.map(RawRule.init))
            personalLexicon = payload.personalLexicon
            userDictionary = payload.userDictionary
            alwaysConvertWords = payload.alwaysConvertWords
            deniedWords = payload.deniedWords
            deniedAppsAdded = payload.deniedAppsAdded
            deniedAppsRemoved = payload.deniedAppsRemoved
        }
    }
}
