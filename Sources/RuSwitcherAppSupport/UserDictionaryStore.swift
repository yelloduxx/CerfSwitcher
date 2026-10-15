import Foundation
import RuSwitcherCore

/// Persistence for the user dictionary in the caller's defaults domain, as a
/// plain string array. Writes come from the settings window, so each change
/// saves at once.
public final class UserDictionaryStore: @unchecked Sendable {
    public static let storageKey = "com.ruswitcher.userDictionary.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var dictionary: UserDictionary

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        dictionary = UserDictionary(words: defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    public var words: [String] { locked { dictionary.words } }

    public var wordsByLanguage: [String: Set<String>] { locked { dictionary.wordsByLanguage } }

    public var exportedText: String { locked { dictionary.exportedText } }

    @discardableResult
    public func add(text: String) -> UserDictionary.Report {
        locked {
            let report = dictionary.add(text: text)
            if report.added > 0 { save() }
            return report
        }
    }

    public func remove(_ words: some Sequence<String>) {
        locked {
            dictionary.remove(words)
            save()
        }
    }

    public func clear() {
        locked {
            dictionary = UserDictionary()
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    private func save() {
        defaults.set(dictionary.words, forKey: Self.storageKey)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
