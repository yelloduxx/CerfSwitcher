import Foundation
import RuSwitcherCore

/// Production persistence for learned pairs. Callers supply their defaults
/// domain explicitly; tests never fall back to the user's standard domain.
public final class LearnedRulesStore: @unchecked Sendable {
    public static let storageKey = "com.ruswitcher.adaptiveRules.v1"

    public struct ImportResult: Equatable, Sendable {
        public let imported: Int
        public let added: Int
        public let total: Int
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var snapshot: AdaptiveRuleBook {
        get { locked { load() } }
        set { locked { _ = save(newValue) } }
    }

    public func recordManualCorrection(original: String, converted: String, appBundleID: String?,
                                       model: LanguageModelStore?) -> ManualLearningDecision {
        locked {
            var book = load()
            let decision = ManualLearningPolicy.decision(original: original, converted: converted,
                                                         appBundleID: appBundleID, ruleBook: book, model: model)
            guard decision != .ignore else { return .ignore }
            decision.apply(to: &book)
            return save(book) ? decision : .ignore
        }
    }

    public func recordPositive(original: String, converted: String) {
        locked {
            var book = load()
            book.recordPositive(original: original, converted: converted)
            _ = save(book)
        }
    }

    public func recordNegative(original: String, converted: String, appBundleID: String?) {
        locked {
            var book = load()
            book.recordNegative(original: original, converted: converted, appBundleID: appBundleID)
            _ = save(book)
        }
    }

    @discardableResult
    public func removeConfirmedPairs(where predicate: (String, String) -> Bool) -> Int {
        locked {
            var book = load()
            let count = book.removeConfirmedPairs(where: predicate)
            if count > 0 { _ = save(book) }
            return count
        }
    }

    public func clear() { locked { defaults.removeObject(forKey: Self.storageKey) } }

    public func exportRules() throws -> Data {
        try locked { try LearnedCorrectionsArchive(ruleBook: load()).encoded() }
    }

    public func importRules(_ data: Data) throws -> ImportResult {
        let imported = try LearnedCorrectionsArchive.decode(data).ruleBook
        return locked {
            var book = load()
            let previous = book.rules
            book.merge(imported)
            let added = book.rules.filter { rule in
                !previous.contains {
                    $0.original == rule.original && $0.converted == rule.converted && $0.appBundleID == rule.appBundleID
                }
            }.count
            _ = save(book)
            return ImportResult(imported: imported.rules.count, added: added, total: book.rules.count)
        }
    }

    private func load() -> AdaptiveRuleBook {
        guard let data = defaults.data(forKey: Self.storageKey),
              let book = try? JSONDecoder().decode(AdaptiveRuleBook.self, from: data) else { return .init() }
        return book
    }

    private func save(_ book: AdaptiveRuleBook) -> Bool {
        guard let data = try? JSONEncoder().encode(book) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
