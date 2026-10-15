import AppKit
import RuSwitcherCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview, keyboard, exceptions, dictionary, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L10n.settingsSectionOverview
        case .keyboard: L10n.settingsSectionKeyboard
        case .exceptions: L10n.settingsSectionExceptions
        case .dictionary: L10n.settingsSectionDictionary
        case .advanced: L10n.settingsTabAdvanced
        case .about: L10n.settingsTabAbout
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .keyboard: "keyboard"
        case .exceptions: "hand.raised.fill"
        case .dictionary: "character.book.closed.fill"
        case .advanced: "gearshape.2.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .blue
        case .keyboard: .indigo
        case .exceptions: .orange
        case .dictionary: .green
        case .advanced: .gray
        case .about: .teal
        }
    }
}

/// Every boolean preference shown in the window, bound to its SettingsManager property.
enum SettingsToggle: CaseIterable {
    case enabled, autoConvert, caretFlag, perAppLayout, launchAtLogin, checkUpdates
    case triggerRightOnly, triggerDoubleTap, axlessConversion, remoteDesktop, debugLog

    var keyPath: ReferenceWritableKeyPath<SettingsManager, Bool> {
        switch self {
        case .enabled: \.autoSwitchEnabled
        case .autoConvert: \.autoConvert
        case .caretFlag: \.caretFlag
        case .perAppLayout: \.perAppLayout
        case .launchAtLogin: \.launchAtLogin
        case .checkUpdates: \.checkUpdatesEnabled
        case .triggerRightOnly: \.triggerRightOnly
        case .triggerDoubleTap: \.triggerDoubleTap
        case .axlessConversion: \.axlessConversion
        case .remoteDesktop: \.remoteDesktopMode
        case .debugLog: \.debugLogEnabled
        }
    }
}

enum SettingsChange {
    case toggle(SettingsToggle, Bool)
    case triggerKey(String)
    case layout1(String)
    case layout2(String)
    case interfaceLanguage(String)
    case addDictionaryWords(String)
    case removeDictionaryWords(Set<String>)
    case removeLearnedEntries(Set<LearnedEntry>)
    case removePersonalWords(Set<PersonalWord>)
    case movePersonalWordsToDictionary(Set<PersonalWord>)
}

enum SettingsAction {
    case checkPermissions, checkUpdates
    case showLog, sendLog
    case exportLearning, importLearning, clearLearning
    case importDictionary, exportDictionary, clearDictionary
    case openGitHub
}

enum DictionaryTab: String, CaseIterable, Identifiable {
    case mine, learned, remembered

    var id: String { rawValue }
}

/// A promoted personal-lexicon word, keyed by the language it was learned in.
struct PersonalWord: Hashable {
    let word: String
    let language: String
}

/// A row of any Dictionary list. `searchKey` is lowercased once when the
/// rows are built, so typing in the search field only scans strings.
protocol DictionaryListRow: Identifiable {
    var searchKey: String { get }
    /// An Exceptions-page rule decides this word instead.
    var overridden: Bool { get }
}

struct WordRow: DictionaryListRow {
    let id: String
    let word: String
    let searchKey: String
    let overridden: Bool
}

struct PersonalRow: DictionaryListRow {
    let id: PersonalWord
    let searchKey: String
    let overridden: Bool
}

struct LearnedRow: DictionaryListRow {
    let id: LearnedEntry
    /// The display name of an exception's application.
    let appName: String?
    let searchKey: String
    let overridden: Bool
}

enum DictionarySearch {
    static func filter<Row: DictionaryListRow>(_ rows: [Row], query: String) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.searchKey.contains(needle) }
    }
}

struct PickerOption: Hashable, Identifiable {
    let id: String
    let title: String
}

enum TriggerOptions {
    // Key names stay unlocalized: they are Apple's standard labels.
    static let single: [PickerOption] = [
        PickerOption(id: "option", title: "Option ⌥ (Alt)"),
        PickerOption(id: "command", title: "Command ⌘"),
        PickerOption(id: "control", title: "Control ⌃"),
        PickerOption(id: "shift", title: "Shift ⇧"),
    ]
    // issue #12: two-modifier combos, the Windows-style Alt+Shift habit.
    static let combos: [PickerOption] = [
        PickerOption(id: "command+shift", title: "⌘ + ⇧  (Command + Shift)"),
        PickerOption(id: "control+shift", title: "⌃ + ⇧  (Control + Shift)"),
        PickerOption(id: "command+option", title: "⌘ + ⌥  (Command + Option)"),
        PickerOption(id: "control+option", title: "⌃ + ⌥  (Control + Option)"),
    ]

    static func keycaps(for key: String) -> [String] {
        let glyphs = ["option": "⌥", "command": "⌘", "control": "⌃", "shift": "⇧"]
        return key.split(separator: "+").compactMap { glyphs[String($0)] }
    }
}

struct PermissionStatus: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool

    var allGranted: Bool { accessibility && inputMonitoring }

    static func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
    }
}

enum HeroState {
    case off, needsPermissions, autoConvert, manualOnly

    var title: String {
        switch self {
        case .off: L10n.settingsHeroOff
        case .needsPermissions: L10n.settingsHeroPermissions
        case .autoConvert: L10n.settingsHeroAuto
        case .manualOnly: L10n.settingsHeroManual
        }
    }

    var detail: String {
        switch self {
        case .off: L10n.settingsHeroOffDetail
        case .needsPermissions: L10n.settingsHeroPermissionsDetail
        case .autoConvert: L10n.settingsHeroAutoDetail
        case .manualOnly: L10n.settingsHeroManualDetail
        }
    }

    var symbol: String {
        switch self {
        case .off: "pause.circle.fill"
        case .needsPermissions: "exclamationmark.triangle.fill"
        case .autoConvert: "checkmark.seal.fill"
        case .manualOnly: "hand.tap.fill"
        }
    }

    var gradient: [Color] {
        switch self {
        case .off: [Color(red: 0.46, green: 0.49, blue: 0.56), Color(red: 0.31, green: 0.33, blue: 0.40)]
        case .needsPermissions: [Color(red: 0.98, green: 0.56, blue: 0.20), Color(red: 0.91, green: 0.30, blue: 0.38)]
        case .autoConvert: [Color(red: 0.16, green: 0.47, blue: 0.98), Color(red: 0.47, green: 0.30, blue: 0.94)]
        case .manualOnly: [Color(red: 0.07, green: 0.62, blue: 0.72), Color(red: 0.18, green: 0.44, blue: 0.90)]
        }
    }
}

/// UI state mirrored from SettingsManager. Writes never touch SettingsManager
/// directly: they go out through `onChange`, which the window controller applies.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .overview {
        didSet { if section != oldValue { loadDictionaryRows() } }
    }
    @Published private(set) var toggles: [SettingsToggle: Bool] = [:]
    @Published private(set) var triggerKey = ""
    @Published private(set) var layout1ID = ""
    @Published private(set) var layout2ID = ""
    @Published private(set) var interfaceLanguage = ""
    @Published var permissions = PermissionStatus(accessibility: false, inputMonitoring: false)
    @Published var dictionaryTab: DictionaryTab = .mine {
        didSet { if dictionaryTab != oldValue { loadDictionaryRows() } }
    }
    @Published var dictionaryCounts: [DictionaryTab: Int] = [:]
    /// Rows exist only for the Dictionary tab on screen; the others stay empty.
    @Published var wordRows: [WordRow] = []
    @Published var learnedRows: [LearnedRow] = []
    @Published var personalRows: [PersonalRow] = []
    /// Counts from the last add, import or export; never the words themselves.
    @Published var dictionaryReport: String?

    let layoutOptions: [PickerOption]
    let languageOptions: [PickerOption]
    let showsRemoteDesktop: Bool

    var onChange: (SettingsChange) -> Void = { _ in }
    var onAction: (SettingsAction) -> Void = { _ in }

    init() {
        layoutOptions = [PickerOption(id: "", title: L10n.settingsAutoDetect)]
            + LayoutSwitcher.installedLayouts().map { layout in
                let id = LayoutSwitcher.sourceID(layout)
                let name = LayoutSwitcher.sourceName(layout)
                return PickerOption(id: id, title: "\(name) (\(id.components(separatedBy: ".").last ?? id))")
            }
        languageOptions = [PickerOption(id: "", title: L10n.settingsLanguageAuto)]
            + L10n.languageNames.map { PickerOption(id: $0.code, title: $0.name) }
        showsRemoteDesktop = SettingsManager.shared.showRemoteDesktopBeta
        refresh()
    }

    func refresh() {
        let settings = SettingsManager.shared
        toggles = Dictionary(uniqueKeysWithValues: SettingsToggle.allCases.map { ($0, settings[keyPath: $0.keyPath]) })
        triggerKey = settings.triggerKey
        layout1ID = settings.layout1ID
        layout2ID = settings.layout2ID
        interfaceLanguage = settings.interfaceLanguage
        permissions = .current()
        dictionaryCounts = [
            .mine: settings.userDictionary.words.count,
            .learned: settings.adaptiveRuleBook.learnedEntries.count,
            .remembered: settings.personalLexicon.promotedWordsByLanguage.values.reduce(0) { $0 + $1.count },
        ]
        loadDictionaryRows()
    }

    /// Reads the store behind the visible Dictionary tab once per change,
    /// not per keystroke.
    private func loadDictionaryRows() {
        let settings = SettingsManager.shared
        let tab = section == .dictionary ? dictionaryTab : nil
        let never = settings.deniedWordsSet
        // Lowercased code-point order: Latin, then Cyrillic. A localized
        // comparison took 70 ms for 20,000 words.
        wordRows = tab != .mine ? [] : settings.userDictionary.words
            .map { word in
                let key = word.lowercased()
                return WordRow(id: key, word: word, searchKey: key, overridden: never.contains(key))
            }
            .sorted { $0.searchKey < $1.searchKey }
        personalRows = tab != .remembered ? [] : settings.personalLexicon.promotedWordsByLanguage
            .flatMap { language, words in words.map { PersonalWord(word: $0, language: language) } }
            .map { PersonalRow(id: $0, searchKey: $0.word, overridden: never.contains($0.word)) }
            .sorted { $0.searchKey < $1.searchKey }
        learnedRows = tab != .learned ? [] : Self.learnedRows(
            settings.adaptiveRuleBook.learnedEntries, never: never, always: settings.alwaysConvertWordsSet,
            appName: appName(for:), isDeniedApp: AutoSwitchPolicy.isDeniedApp
        )
    }

    /// A pair is overridden when either spelling is never converted; an
    /// application exception also when always-convert or a denied
    /// application decides for it.
    static func learnedRows(
        _ entries: [LearnedEntry], never: Set<String>, always: Set<String>,
        appName: (String) -> String, isDeniedApp: (String) -> Bool
    ) -> [LearnedRow] {
        entries.map { entry in
            let original = SmartTokenizer.lexicalCore(of: entry.original)
            let converted = SmartTokenizer.lexicalCore(of: entry.converted)
            let name = entry.exceptionAppBundleID.map(appName)
            var overridden = never.contains(original) || never.contains(converted)
            if let app = entry.exceptionAppBundleID {
                overridden = overridden || always.contains(converted) || isDeniedApp(app)
            }
            return LearnedRow(
                id: entry, appName: name,
                searchKey: [entry.original, entry.converted, name?.lowercased() ?? ""].joined(separator: " "),
                overridden: overridden
            )
        }
    }

    private var appNames: [String: String] = [:]

    private func appName(for bundleID: String) -> String {
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? bundleID
        appNames[bundleID] = name
        return name
    }

    var heroState: HeroState {
        if !isOn(.enabled) { return .off }
        if !permissions.allGranted { return .needsPermissions }
        return isOn(.autoConvert) ? .autoConvert : .manualOnly
    }

    func isOn(_ toggle: SettingsToggle) -> Bool { toggles[toggle] ?? false }

    func binding(_ toggle: SettingsToggle) -> Binding<Bool> {
        Binding(get: { self.isOn(toggle) }, set: { self.set(toggle, $0) })
    }

    func set(_ toggle: SettingsToggle, _ value: Bool) {
        guard isOn(toggle) != value else { return }
        toggles[toggle] = value
        onChange(.toggle(toggle, value))
    }

    /// A stored value missing from the menu shows the first entry, as the old popups did.
    private func shown(_ id: String, in options: [PickerOption]) -> String {
        options.contains { $0.id == id } ? id : options.first?.id ?? ""
    }

    var triggerBinding: Binding<String> {
        Binding(get: { self.shown(self.triggerKey, in: TriggerOptions.single + TriggerOptions.combos) }, set: { key in
            self.triggerKey = key
            self.onChange(.triggerKey(key))
        })
    }

    var layout1Binding: Binding<String> {
        Binding(get: { self.shown(self.layout1ID, in: self.layoutOptions) }, set: { id in
            self.layout1ID = id
            self.onChange(.layout1(id))
        })
    }

    var layout2Binding: Binding<String> {
        Binding(get: { self.shown(self.layout2ID, in: self.layoutOptions) }, set: { id in
            self.layout2ID = id
            self.onChange(.layout2(id))
        })
    }

    var languageBinding: Binding<String> {
        Binding(get: { self.shown(self.interfaceLanguage, in: self.languageOptions) }, set: { code in
            self.interfaceLanguage = code
            self.onChange(.interfaceLanguage(code))
        })
    }
}
