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

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
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

    /// Returns true when the promoted set changed.
    @discardableResult
    public func observe(word: String, language: String, at date: Date = Date()) -> Bool {
        locked {
            let changed = lexicon.observe(word: word, language: language, at: date)
            dirty = true
            return changed
        }
    }

    @discardableResult
    public func remove(word: String, language: String) -> Bool {
        locked {
            let hadEntry = lexicon.entries.count
            let changed = lexicon.remove(word: word, language: language)
            dirty = dirty || hadEntry != lexicon.entries.count
            return changed
        }
    }

    public func flush() {
        locked {
            guard dirty, let data = try? JSONEncoder().encode(lexicon) else { return }
            defaults.set(data, forKey: Self.storageKey)
            dirty = false
        }
    }

    public func clear() {
        locked {
            lexicon = PersonalLexicon()
            dirty = false
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
