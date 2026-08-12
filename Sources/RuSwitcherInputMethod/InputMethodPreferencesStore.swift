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

    init(defaults: UserDefaults? = UserDefaults(suiteName: "com.ruswitcher.pro")) {
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
        guard !original.contains(where: \.isWhitespace),
              !converted.contains(where: \.isWhitespace),
              let model = LanguageModelStore.bundled,
              ManualLearningPolicy.shouldPersist(
                  original: original,
                  converted: converted,
                  model: model
              )
        else { return }
        var rules = snapshot(appBundleID: appBundleID).adaptiveRules
        rules.recordManualCorrection(
            original: original,
            converted: converted,
            appBundleID: appBundleID
        )
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Keys.adaptiveRules)
    }
}
