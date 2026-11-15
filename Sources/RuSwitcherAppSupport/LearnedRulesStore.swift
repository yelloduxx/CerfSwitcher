import Foundation
import RuSwitcherCore

/// Production persistence for learned pairs. Callers supply their defaults
/// domain explicitly; tests never fall back to the user's standard domain.
public final class LearnedRulesStore: @unchecked Sendable {
    public static let storageKey = "com.ruswitcher.adaptiveRules.v1"
    public static let neverConvertWordsKey = "com.ruswitcher.deniedWords"

    public struct ImportResult: Equatable, Sendable {
        public let imported: Int
        public let added: Int
        public let total: Int
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// The decoder reads the rules several times per word; decode the stored
    /// bytes again only when they changed, whoever wrote them.
    private var cachedData: Data?
    private var cachedBook = AdaptiveRuleBook()
    private var cachedDataIsValid = true
    private let receiptOwner = UUID()
    private var receipts = ReceiptWindow<RuleKey>()

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private var wordPolicy: AutoConvertPolicy {
        AutoConvertPolicy(neverConvert: Set(defaults.stringArray(forKey: Self.neverConvertWordsKey) ?? []),
                          alwaysConvert: [])
    }

    public var snapshot: AdaptiveRuleBook {
        get { locked { load() } }
        set { locked { _ = load(); receipts.clear(); _ = save(newValue) } }
    }

    /// Explicit full restore. The legacy snapshot setter remains source compatible.
    public func replace(with replacement: AdaptiveRuleBook) throws {
        try PersonalDataArchive.validateAdaptiveRules(replacement)
        try locked {
            _ = load()
            try saveVerified(replacement)
            receipts.clear()
        }
    }

    public func recordManualCorrection(original: String, converted: String, appBundleID: String?,
                                       model: LanguageModelStore?) -> ManualLearningDecision {
        (try? saveManualCorrection(original: original, converted: converted,
                                  appBundleID: appBundleID, model: model))?.decision ?? .ignore
    }

    /// A result acknowledges a byte-for-byte defaults read-back, not an fsync.
    public func saveManualCorrection(original: String, converted: String, appBundleID: String?,
                                     model: LanguageModelStore?) throws -> ManualLearningSave? {
        try saveDecision { book in
            ManualLearningPolicy.decision(original: original, converted: converted,
                                          appBundleID: appBundleID, ruleBook: book, model: model,
                                          neverConvert: self.wordPolicy.neverConvert)
        }
    }

    public func saveApplicationException(original: String, converted: String,
                                         appBundleID: String?) throws -> ManualLearningSave? {
        try saveDecision { book in
            guard !self.wordPolicy.excludes(original: original, converted: converted),
                  let appBundleID, !appBundleID.isEmpty,
                  book.isConfirmed(original: original, converted: converted, appBundleID: nil) else { return .ignore }
            return .applicationException(original: original, converted: converted, appBundleID: appBundleID)
        }
    }

    private func saveDecision(_ decide: (AdaptiveRuleBook) -> ManualLearningDecision) throws -> ManualLearningSave? {
        try locked {
            var book = load()
            guard cachedDataIsValid, book.modelVersion == 8 else { throw PersonalDataStoreError.invalidStoredData }
            guard book.rules.count <= LearnedCorrectionsArchive.maximumRuleCount else {
                throw PersonalDataStoreError.capacityExceeded
            }
            try PersonalDataArchive.validateAdaptiveRules(book)
            let before = book
            let decision = decide(book)
            guard decision != .ignore else { return nil }
            decision.apply(to: &book)
            try PersonalDataArchive.validateAdaptiveRules(book)
            let changes = RuleChange.between(before.rules, book.rules)
            guard !changes.isEmpty else { return nil }
            try saveVerified(book)
            let id = receipts.insert(keys: Set(changes.map(\.key)))
            return ManualLearningSave(decision: decision, receipt: ManualLearningReceipt(
                owner: receiptOwner, id: id, changes: changes
            ))
        }
    }

    /// Checks without writing or consuming the receipt. This is not a reservation;
    /// callers serialize their operations, and undo checks again before saving.
    public func validateUndo(_ receipt: ManualLearningReceipt) -> PersonalDataUndoResult? {
        locked {
            guard receipt.owner == receiptOwner else { return .invalidReceipt }
            let book = load()
            guard cachedDataIsValid else { return .conflict }
            return undoStatus(receipt, in: book)
        }
    }

    private func undoStatus(_ receipt: ManualLearningReceipt, in book: AdaptiveRuleBook) -> PersonalDataUndoResult? {
        if let status = receipts.status(receipt.id) { return status }
        let current = Dictionary(grouping: book.rules, by: RuleKey.init)
        guard receipt.changes.allSatisfy({ (current[$0.key] ?? []) == $0.after }) else { return .conflict }
        let restoredCount = book.rules.count + receipt.changes.reduce(0) { $0 + $1.before.count - $1.after.count }
        // Restoring pruned entries must not evict newer unrelated rules.
        return restoredCount <= LearnedCorrectionsArchive.maximumRuleCount ? nil : .conflict
    }

    public func undo(_ receipt: ManualLearningReceipt) throws -> PersonalDataUndoResult {
        try locked {
            guard receipt.owner == receiptOwner else { return .invalidReceipt }
            let book = load()
            guard cachedDataIsValid else { throw PersonalDataStoreError.invalidStoredData }
            if let status = undoStatus(receipt, in: book) { return status }
            let affected = Set(receipt.changes.map(\.key))
            var restored = book.rules.filter { !affected.contains(RuleKey($0)) }
            for previous in receipt.changes.flatMap(\.before).sorted(by: { $0.index < $1.index }) {
                restored.insert(previous.rule, at: min(previous.index, restored.count))
            }
            try saveVerified(AdaptiveRuleBook(rules: restored, modelVersion: book.modelVersion))
            receipts.consume(receipt.id)
            return .undone
        }
    }

    public func recordPositive(original: String, converted: String) {
        locked {
            guard !wordPolicy.excludes(original: original, converted: converted) else { return }
            var book = load()
            // Weak reinforcement adds no evidence to a confirmation and would invalidate its undo receipt.
            guard !book.isConfirmed(original: original, converted: converted, appBundleID: nil) else { return }
            book.recordPositive(original: original, converted: converted)
            _ = save(book)
        }
    }

    public func recordNegative(original: String, converted: String, appBundleID: String?) {
        locked {
            guard !wordPolicy.excludes(original: original, converted: converted) else { return }
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

    /// Deletes what the user removed in Settings. The decoder reads the store
    /// on every decision, so the next word already sees the change.
    @discardableResult
    public func remove(_ entries: some Sequence<LearnedEntry>) -> Int {
        locked {
            var book = load()
            let count = book.remove(entries)
            if count > 0 { _ = save(book) }
            return count
        }
    }

    public func clear() {
        locked {
            receipts.clear()
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    public func exportRules() throws -> Data {
        try locked { try LearnedCorrectionsArchive(ruleBook: load()).encoded() }
    }

    public func importRules(_ data: Data) throws -> ImportResult {
        let imported = try LearnedCorrectionsArchive.decode(data).ruleBook
        return try locked {
            var book = load()
            let previous = book.rules
            book.merge(imported)
            let added = book.rules.filter { rule in
                !previous.contains {
                    $0.original == rule.original && $0.converted == rule.converted && $0.appBundleID == rule.appBundleID
                }
            }.count
            try saveVerified(book)
            return ImportResult(imported: imported.rules.count, added: added, total: book.rules.count)
        }
    }

    private func load() -> AdaptiveRuleBook {
        let data = defaults.data(forKey: Self.storageKey)
        if data == cachedData { return cachedBook }
        let decoded = data.flatMap { try? JSONDecoder().decode(AdaptiveRuleBook.self, from: $0) }
        let book = decoded ?? .init()
        cachedDataIsValid = data == nil || decoded != nil
        if cachedDataIsValid, cachedBook.modelVersion == book.modelVersion {
            receipts.invalidate(keys: Set(RuleChange.between(cachedBook.rules, book.rules).map(\.key)))
        } else {
            receipts.clear()
        }
        cachedData = data
        cachedBook = book
        return book
    }

    private func save(_ book: AdaptiveRuleBook) -> Bool {
        do { try saveVerified(book); return true } catch { return false }
    }

    private func saveVerified(_ book: AdaptiveRuleBook) throws {
        let before = cachedBook
        let data = try JSONEncoder().encode(book)
        guard defaults.data(forKey: Self.storageKey) == cachedData else {
            throw PersonalDataStoreError.externalChange
        }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else {
            receipts.clear()
            throw PersonalDataStoreError.readBackFailed
        }
        receipts.invalidate(keys: Set(RuleChange.between(before.rules, book.rules).map(\.key)))
        cachedData = data
        cachedBook = book
        cachedDataIsValid = true
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
