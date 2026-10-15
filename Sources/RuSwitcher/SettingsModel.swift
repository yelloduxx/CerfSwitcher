import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview, keyboard, exceptions, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L10n.settingsSectionOverview
        case .keyboard: L10n.settingsSectionKeyboard
        case .exceptions: L10n.settingsSectionExceptions
        case .advanced: L10n.settingsTabAdvanced
        case .about: L10n.settingsTabAbout
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .keyboard: "keyboard"
        case .exceptions: "hand.raised.fill"
        case .advanced: "gearshape.2.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .blue
        case .keyboard: .indigo
        case .exceptions: .orange
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
}

enum SettingsAction {
    case checkPermissions, checkUpdates
    case showLog, sendLog
    case exportLearning, importLearning, clearLearning
    case openGitHub
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
    @Published var section: SettingsSection = .overview
    @Published private(set) var toggles: [SettingsToggle: Bool] = [:]
    @Published private(set) var triggerKey = ""
    @Published private(set) var layout1ID = ""
    @Published private(set) var layout2ID = ""
    @Published private(set) var interfaceLanguage = ""
    @Published var permissions = PermissionStatus(accessibility: false, inputMonitoring: false)

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
