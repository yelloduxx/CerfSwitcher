import Foundation
import RuSwitcherCore

final class InputMethodPreferencesStore {
    private enum Keys {
        static let autoConvert = "com.ruswitcher.autoConvert"
        static let deniedWords = "com.ruswitcher.deniedWords"
        static let alwaysConvertWords = "com.ruswitcher.alwaysConvertWords"
        static let adaptiveRules = "com.ruswitcher.adaptiveRules.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: "com.cerfswitcher.app")) {
        self.defaults = defaults ?? .standard
    }

    func snapshot(appBundleID: String?) -> InputMethodCompositionPreferences {
        let never = Set((defaults.stringArray(forKey: Keys.deniedWords) ?? []).map {
            FrequentWordLexicon.normalize($0)
        })
        let always = Set((defaults.stringArray(forKey: Keys.alwaysConvertWords) ?? []).map {
            FrequentWordLexicon.normalize($0)
        })
        let rules: AdaptiveRuleBook
        if let data = defaults.data(forKey: Keys.adaptiveRules),
           let decoded = try? JSONDecoder().decode(AdaptiveRuleBook.self, from: data) {
            rules = decoded
        } else {
            rules = AdaptiveRuleBook()
        }
        // Selecting this input source is explicit opt-in. If the main app has a
        // stored preference, however, both products honor it.
        let enabled = defaults.object(forKey: Keys.autoConvert) as? Bool ?? true
        return InputMethodCompositionPreferences(
            automaticConversionEnabled: enabled,
            policy: AutoConvertPolicy(neverConvert: never, alwaysConvert: always),
            adaptiveRules: rules,
            appBundleID: appBundleID
        )
    }

    func recordManualCorrection(original: String, converted: String, appBundleID: String?) {
        var rules = snapshot(appBundleID: appBundleID).adaptiveRules
        let decision = ManualLearningPolicy.decision(
            original: original, converted: converted, appBundleID: appBundleID,
            ruleBook: rules, model: LanguageModelStore.bundled
        )
        guard decision != .ignore else { return }
        decision.apply(to: &rules)
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Keys.adaptiveRules)
    }
}
