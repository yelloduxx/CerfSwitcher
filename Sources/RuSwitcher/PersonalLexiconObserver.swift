import ApplicationServices
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

/// Feeds kept tokens into the personal lexicon off the event-tap thread and
/// keeps one personalized model for the automatic decoder. Secure input and
/// denied applications never reach here; this adds the focused field's own
/// role: a password field is skipped, a field AX cannot read is allowed
/// because secure input is the operating system's guard for that case.
final class PersonalLexiconObserver: @unchecked Sendable {
    private let store: PersonalLexiconStore
    private let base: LanguageModelStore?
    private let resolver: NativeFocusedEditableResolver
    private let queue = DispatchQueue(label: "com.ruswitcher.personal-lexicon", qos: .utility)
    private let lock = NSLock()
    private var cachedModel: LanguageModelStore?
    private var fieldVerdicts: [String: (allowed: Bool, at: Date)] = [:]
    private var flushScheduled = false

    private static let fieldVerdictLifetime: TimeInterval = 60
    private static let flushDelay: TimeInterval = 3

    init(store: PersonalLexiconStore, base: LanguageModelStore?, resolver: NativeFocusedEditableResolver) {
        self.store = store
        self.base = base
        self.resolver = resolver
        cachedModel = base?.personalized(with: store.promotedWordsByLanguage)
    }

    var model: LanguageModelStore? {
        lock.lock()
        defer { lock.unlock() }
        return cachedModel
    }

    func observe(typed: String, language: String, focus: FocusedElementIdentity) {
        guard let base, let word = PersonalLexicon.eligibleWord(typed: typed, language: language, model: base) else {
            return
        }
        queue.async { [self] in
            guard fieldAllowsLearning(focus) else { return }
            if store.observe(word: word, language: language) { refreshModel() }
            scheduleFlush()
        }
    }

    /// The user converted this spelling by hand, so it is not one of their words.
    func forget(original: String, language: String) {
        let word = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: original))
        guard !word.isEmpty else { return }
        queue.async { [self] in
            if store.remove(word: word, language: language) { refreshModel() }
            scheduleFlush()
        }
    }

    func flush() {
        queue.sync { store.flush() }
    }

    private func refreshModel() {
        let model = base?.personalized(with: store.promotedWordsByLanguage)
        lock.lock()
        cachedModel = model
        lock.unlock()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.flushDelay) { [self] in
            flushScheduled = false
            store.flush()
        }
    }

    private func fieldAllowsLearning(_ focus: FocusedElementIdentity) -> Bool {
        let key = "\(focus.processID)\u{1f}\(focus.identifier ?? focus.bundleID ?? "")"
        let now = Date()
        if let verdict = fieldVerdicts[key], now.timeIntervalSince(verdict.at) < Self.fieldVerdictLifetime {
            return verdict.allowed
        }
        let allowed: Bool
        switch resolver.withElement(processID: focus.processID, timeoutMilliseconds: 50, operation: { lease in
            let subrole = lease.copyAttribute(kAXSubroleAttribute as CFString)
            return subrole.0 == .success && (subrole.1 as? String) == (kAXSecureTextFieldSubrole as String)
        }) {
        case let .value(secure):
            allowed = !secure
        case .unavailable(.timedOut):
            allowed = true
        case .unavailable:
            allowed = false
        }
        if fieldVerdicts.count > 256 { fieldVerdicts.removeAll() }
        fieldVerdicts[key] = (allowed, now)
        return allowed
    }
}
