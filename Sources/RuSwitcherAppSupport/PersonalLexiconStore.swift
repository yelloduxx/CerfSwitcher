import Foundation
import RuSwitcherCore

/// Persistence for the personal lexicon in the caller's defaults domain.
/// Sightings arrive from the event path, so saving is deferred: `flush()`
/// writes once, and callers schedule it off the callback.
public final class PersonalLexiconStore: @unchecked Sendable {
    public static let storageKey = "com.ruswitcher.personalLexicon.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var lexicon: PersonalLexicon
    private var dirty = false
    private var persistedData: Data?
    private let receiptOwner = UUID()
    private var receipts = ReceiptWindow<String>()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        persistedData = defaults.data(forKey: Self.storageKey)
        if let data = persistedData,
           let stored = try? JSONDecoder().decode(PersonalLexicon.self, from: data) {
            lexicon = stored
        } else {
            lexicon = PersonalLexicon()
        }
    }

    public var promotedWordsByLanguage: [String: Set<String>] {
        locked { lexicon.promotedWordsByLanguage }
    }

    public var entryCount: Int { locked { lexicon.entries.count } }

    /// Includes pending sightings; callers drain the observer queue before backup.
    public var snapshot: PersonalLexicon { locked { lexicon } }

    public func replace(with replacement: PersonalLexicon) throws {
        try PersonalDataArchive.validatePersonalLexicon(replacement)
        try locked {
            try persist(replacement, replacingAll: true)
            receipts.clear()
        }
    }

    /// Persists the removal and pending sightings before returning a receipt.
    public func removeWithReceipt(word: String, language: String) throws -> PersonalLexiconRemovalReceipt? {
        try locked {
            try refreshForUndo()
            try PersonalDataArchive.validatePersonalLexicon(lexicon)
            let key = Self.key(word, language)
            guard let entry = lexicon.entries[key] else { return nil }
            var updated = lexicon
            updated.entries.removeValue(forKey: key)
            try persist(updated)
            let id = receipts.insert(keys: [key])
            return PersonalLexiconRemovalReceipt(wasPromoted: entry.promoted, owner: receiptOwner,
                                                 id: id, key: key, entry: entry)
        }
    }

    /// Checks without persisting sightings or consuming the receipt. Undo rechecks.
    public func validateUndo(_ receipt: PersonalLexiconRemovalReceipt) -> PersonalDataUndoResult? {
        locked {
            guard receipt.owner == receiptOwner else { return .invalidReceipt }
            do { try refreshForUndo() } catch { return .conflict }
            return undoStatus(receipt)
        }
    }

    private func undoStatus(_ receipt: PersonalLexiconRemovalReceipt) -> PersonalDataUndoResult? {
        if let status = receipts.status(receipt.id) { return status }
        guard lexicon.entries[receipt.key] == nil else { return .conflict }
        var restored = lexicon
        restored.entries[receipt.key] = receipt.entry
        do { try PersonalDataArchive.validatePersonalLexicon(restored) }
        catch { return .conflict }
        return nil
    }

    public func undo(_ receipt: PersonalLexiconRemovalReceipt) throws -> PersonalDataUndoResult {
        try locked {
            guard receipt.owner == receiptOwner else { return .invalidReceipt }
            try refreshForUndo()
            if let status = undoStatus(receipt) { return status }
            var restored = lexicon
            restored.entries[receipt.key] = receipt.entry
            try persist(restored)
            receipts.consume(receipt.id)
            return .undone
        }
    }

    /// Returns true when the promoted set changed.
    @discardableResult
    public func observe(word: String, language: String, at date: Date = Date()) -> Bool {
        locked {
            let key = Self.key(word, language)
            let before = lexicon.entries[key]
            let changed = lexicon.observe(word: word, language: language, at: date)
            if before != lexicon.entries[key] { receipts.invalidate(keys: [key]) }
            dirty = true
            return changed
        }
    }

    @discardableResult
    public func remove(word: String, language: String) -> Bool {
        locked {
            let hadEntry = lexicon.entries.count
            let changed = lexicon.remove(word: word, language: language)
            if hadEntry != lexicon.entries.count { receipts.invalidate(keys: [Self.key(word, language)]) }
            dirty = dirty || hadEntry != lexicon.entries.count
            return changed
        }
    }

    public func flush() {
        locked {
            guard dirty, defaults.data(forKey: Self.storageKey) == persistedData else { return }
            try? persist(lexicon)
        }
    }

    public func clear() {
        locked {
            lexicon = PersonalLexicon()
            dirty = false
            persistedData = nil
            receipts.clear()
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    private static func key(_ word: String, _ language: String) -> String {
        LanguageCode.canonical(language) + "\u{1f}" + FrequentWordLexicon.normalize(word)
    }

    private func invalidateChanges(from before: PersonalLexicon, to after: PersonalLexicon) {
        let keys = Set(before.entries.keys).union(after.entries.keys).filter { before.entries[$0] != after.entries[$0] }
        receipts.invalidate(keys: Set(keys))
    }

    private func refreshForUndo() throws {
        let data = defaults.data(forKey: Self.storageKey)
        guard data != persistedData else { return }
        // Never discard unflushed local sightings to load another writer's data.
        guard !dirty else { throw PersonalDataStoreError.externalChange }
        let updated: PersonalLexicon
        if let data {
            guard let decoded = try? JSONDecoder().decode(PersonalLexicon.self, from: data) else {
                throw PersonalDataStoreError.invalidStoredData
            }
            try PersonalDataArchive.validatePersonalLexicon(decoded)
            updated = decoded
        } else {
            updated = PersonalLexicon()
            receipts.clear()
        }
        invalidateChanges(from: lexicon, to: updated)
        lexicon = updated
        persistedData = data
    }

    private func persist(_ updated: PersonalLexicon, replacingAll: Bool = false) throws {
        let data = try JSONEncoder().encode(updated)
        guard replacingAll || defaults.data(forKey: Self.storageKey) == persistedData else {
            throw PersonalDataStoreError.externalChange
        }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else {
            receipts.clear()
            throw PersonalDataStoreError.readBackFailed
        }
        invalidateChanges(from: lexicon, to: updated)
        lexicon = updated
        persistedData = data
        dirty = false
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
