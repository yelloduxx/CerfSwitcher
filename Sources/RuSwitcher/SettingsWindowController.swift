import AppKit
import RuSwitcherCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    private var becomeKeyObserver: NSObjectProtocol?

    /// Callback для обновления меню
    var onAutoSwitchChanged: ((Bool) -> Void)?
    var onPerAppLayoutChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onTriggerChanged: (() -> Void)?
    var onAutoConvertChanged: ((Bool) -> Void)?
    var onRemoteDesktopChanged: ((Bool) -> Void)?
    var onCaretFlagChanged: ((Bool) -> Void)?
    var onCheckPermissions: (() -> Void)?
    /// The user dictionary or the personal lexicon changed; the decoder's
    /// personalized model needs rebuilding.
    var onVocabularyChanged: (() -> Void)?
    var onLearnedRulesRemoved: (() -> Void)?

    func showWindow(section: SettingsSection = .overview) {
        if let window {
            model?.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = makeModel(section: section)
        let win = Self.makeWindow(content: NSHostingView(rootView: SettingsRootView(model: model)))
        win.center()
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.refresh() }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
        self.model = model
    }

    static func makeWindow(content: NSView) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.settingsTitle
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.contentView = content
        return win
    }

    /// Every settings page as a standalone view, for offscreen snapshots.
    func snapshotPages() -> [(name: String, view: NSView)] {
        var pages: [(name: String, view: NSView)] = SettingsSection.allCases.map { section in
            (section.rawValue, NSHostingView(rootView: SettingsRootView(model: makeModel(section: section))))
        }
        let ready = makeModel(section: .overview)
        ready.onChange = { _ in }
        ready.permissions = PermissionStatus(accessibility: true, inputMonitoring: true)
        ready.set(.autoConvert, true)
        ready.set(.caretFlag, true)
        pages.append(("overview-ready", NSHostingView(rootView: SettingsRootView(model: ready))))
        let samples = Self.sampleDictionary()
        for tab in DictionaryTab.allCases {
            let model = makeModel(section: .dictionary)
            model.onChange = { _ in }
            model.dictionaryTab = tab
            model.dictionaryCounts = [.mine: samples.words.count, .learned: samples.learned.count,
                                      .remembered: samples.remembered.count]
            model.dictionaryReport = Self.describe(UserDictionary.Report(added: 8, duplicates: 1, invalid: 2))
            model.wordRows = tab == .mine ? samples.words : []
            model.learnedRows = tab == .learned ? samples.learned : []
            model.personalRows = tab == .remembered ? samples.remembered : []
            let name = tab == .mine ? "dictionary-filled" : "dictionary-\(tab.rawValue)"
            pages.append((name, NSHostingView(rootView: SettingsRootView(model: model))))
        }
        return pages
    }

    /// Made-up Dictionary contents for snapshots; never the user's own words.
    private static func sampleDictionary() -> (words: [WordRow], learned: [LearnedRow], remembered: [PersonalRow]) {
        let never: Set<String> = ["tesla", "ntcn", "деплой"]
        let words = ["Figma", "Kubernetes", "Nuxt", "pstack", "Tesla", "вайб", "кринж", "Яндекс"].map {
            WordRow(id: $0.lowercased(), word: $0, searchKey: $0.lowercased(), overridden: never.contains($0.lowercased()))
        }
        let entries = [
            LearnedEntry(original: "ghbdtn", converted: "привет"),
            LearnedEntry(original: "rjvgm.nth", converted: "компьютер"),
            LearnedEntry(original: "ghbdtn", converted: "привет", exceptionAppBundleID: "sample.chat"),
            LearnedEntry(original: "ntcn", converted: "тест"),
            LearnedEntry(original: "ctujlyz", converted: "сегодня"),
            LearnedEntry(original: "руддщ", converted: "hello"),
            LearnedEntry(original: "dfqa", converted: "вайф", exceptionAppBundleID: "sample.notes"),
            LearnedEntry(original: "pfdnhf", converted: "завтра"),
            LearnedEntry(original: "кщфвьфз", converted: "roadmap"),
            LearnedEntry(original: "yfcnhjqrb", converted: "настройки"),
        ]
        let learned = SettingsModel.learnedRows(
            entries, never: never, always: ["вайф"],
            appName: { ["sample.chat": "Telegram", "sample.notes": "Notes"][$0] ?? $0 }, isDeniedApp: { _ in false }
        )
        let remembered = [("деплой", "ru"), ("линтер", "ru"), ("ок", "ru"), ("pnpm", "en"), ("вайбкод", "ru"), ("zod", "en")]
            .map { PersonalRow(id: PersonalWord(word: $0.0, language: $0.1), searchKey: $0.0, overridden: never.contains($0.0)) }
        return (words, learned, remembered)
    }

    /// Обновить состояние переключателя автопереключения извне
    func updateAutoSwitchState(_ enabled: Bool) {
        model?.refresh()
    }

    /// Обновить переключатель «флаг у курсора» извне (когда переключили из меню)
    func updateCaretFlagState(_ enabled: Bool) {
        model?.refresh()
    }

    private func makeModel(section: SettingsSection) -> SettingsModel {
        let model = SettingsModel()
        model.section = section
        model.onChange = { [weak self] change in self?.apply(change) }
        model.onAction = { [weak self] action in self?.perform(action) }
        return model
    }

    // MARK: - Changes

    private func apply(_ change: SettingsChange) {
        let settings = SettingsManager.shared
        switch change {
        case let .toggle(toggle, enabled):
            settings[keyPath: toggle.keyPath] = enabled
            switch toggle {
            case .enabled: onAutoSwitchChanged?(enabled)
            case .autoConvert: onAutoConvertChanged?(enabled)
            case .caretFlag: onCaretFlagChanged?(enabled)
            case .perAppLayout: onPerAppLayoutChanged?(enabled)
            case .remoteDesktop: onRemoteDesktopChanged?(enabled)
            case .triggerRightOnly, .triggerDoubleTap: onTriggerChanged?()
            case .launchAtLogin, .checkUpdates, .axlessConversion, .debugLog: break
            }
        case let .triggerKey(key):
            settings.triggerKey = key
            onTriggerChanged?()
        case let .layout1(id):
            settings.layout1ID = id
            DynamicKeyMapping.clearCache()
        case let .layout2(id):
            settings.layout2ID = id
            DynamicKeyMapping.clearCache()
        case let .interfaceLanguage(code):
            settings.interfaceLanguage = code  // вызывает L10n.reloadLanguage()
            onLanguageChanged?()  // пересобрать меню статус-бара под новый язык
            // Static L10n strings only re-read on a fresh window; rebuild it
            // after the picker's own update finishes.
            let section = model?.section ?? .overview
            DispatchQueue.main.async { [weak self] in
                self?.closeWindow()
                self?.showWindow(section: section)
            }
        case let .addDictionaryWords(text):
            dictionaryChanged(report: Self.describe(settings.userDictionary.add(text: text)))
        case let .removeDictionaryWords(words):
            settings.userDictionary.remove(words)
            dictionaryChanged(report: nil)
        case let .removeLearnedEntries(entries):
            settings.removeLearnedEntries(entries)
            onLearnedRulesRemoved?()
            model?.refresh()
            rslog("learned_rules_removed")
        case let .removePersonalWords(words):
            removePersonalWords(words)
            dictionaryChanged(report: nil)
            rslog("personal_words_removed")
        case let .movePersonalWordsToDictionary(words):
            let report = settings.userDictionary.add(text: words.map(\.word).joined(separator: "\n"))
            // A word the dictionary rejects stays where it was.
            removePersonalWords(words.filter { settings.userDictionary.contains($0.word) })
            dictionaryChanged(report: Self.describe(report))
            rslog("personal_words_moved")
        }
    }

    private func removePersonalWords(_ words: some Sequence<PersonalWord>) {
        let lexicon = SettingsManager.shared.personalLexicon
        for word in words {
            lexicon.remove(word: word.word, language: word.language)
        }
        lexicon.flush()
    }

    private func dictionaryChanged(report: String?) {
        onVocabularyChanged?()
        model?.refresh()
        model?.dictionaryReport = report
    }

    static func describe(_ report: UserDictionary.Report) -> String {
        let added = String(format: L10n.settingsDictionaryAdded, report.added)
        guard report.skipped > 0 else { return added }
        let reasons = [
            (report.duplicates, L10n.settingsDictionarySkippedDuplicates),
            (report.invalid, L10n.settingsDictionarySkippedInvalid),
            (report.overLimit, L10n.settingsDictionarySkippedLimit),
        ].filter { $0.0 > 0 }.map { String(format: $0.1, $0.0) }
        return added + " " + String(format: L10n.settingsDictionarySkipped, report.skipped, reasons.joined(separator: ", "))
    }

    private func closeWindow() {
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
        becomeKeyObserver = nil
        window?.close()
        window = nil
        model = nil
    }

    private func perform(_ action: SettingsAction) {
        switch action {
        case .checkPermissions: onCheckPermissions?()
        case .checkUpdates: UpdateChecker.checkNow()
        case .showLog: showLogFile()
        case .sendLog: sendLogFile()
        case .exportLearning: exportAdaptiveLearning()
        case .importLearning: importAdaptiveLearning()
        case .clearLearning: clearAdaptiveLearning()
        case .importDictionary: importDictionary()
        case .exportDictionary: exportDictionary()
        case .clearDictionary: clearDictionary()
        case .openGitHub: openGitHub()
        }
    }

    // MARK: - Actions

    private func clearAdaptiveLearning() {
        let alert = NSAlert()
        alert.messageText = L10n.settingsClearLearningConfirm
        alert.addButton(withTitle: L10n.settingsClearLearning)
        alert.addButton(withTitle: L10n.commonCancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsManager.shared.clearAdaptiveRules()
        rslog("learn: adaptive rules cleared")
    }

    private func exportAdaptiveLearning() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ProductIdentity.shortName)-Learned-Corrections-\(Self.exportDateString()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SettingsManager.shared.exportLearnedCorrections()
            try data.write(to: url, options: .atomic)
            let count = SettingsManager.shared.adaptiveRuleBook.rules.count
            showLearningAlert(
                title: L10n.settingsExportLearning,
                detail: String(format: L10n.settingsExportLearningSuccess, count)
            )
        } catch {
            showLearningAlert(title: L10n.settingsLearningFileError, detail: error.localizedDescription)
        }
    }

    private func importAdaptiveLearning() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let result = try SettingsManager.shared.importLearnedCorrections(data)
            showLearningAlert(
                title: L10n.settingsImportLearning,
                detail: String(
                    format: L10n.settingsImportLearningSuccess,
                    result.imported,
                    result.added,
                    result.total
                )
            )
            rslog("learning_rules_imported")
        } catch {
            showLearningAlert(title: L10n.settingsLearningFileError, detail: error.localizedDescription)
        }
    }

    private static let dictionaryFileLimit = 5 * 1024 * 1024

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.dictionaryFileLimit else {
                showLearningAlert(title: L10n.settingsDictionaryFileError, detail: L10n.settingsDictionaryFileTooLarge)
                return
            }
            guard let text = UserDictionary.decodeFile(try Data(contentsOf: url)) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            dictionaryChanged(report: Self.describe(SettingsManager.shared.userDictionary.add(text: text)))
            rslog("user_dictionary_imported")
        } catch {
            showLearningAlert(title: L10n.settingsDictionaryFileError, detail: error.localizedDescription)
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ProductIdentity.shortName)-Dictionary-\(Self.exportDateString()).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dictionary = SettingsManager.shared.userDictionary
        do {
            try Data(dictionary.exportedText.utf8).write(to: url, options: .atomic)
            model?.dictionaryReport = String(format: L10n.settingsDictionaryExported, dictionary.words.count)
        } catch {
            showLearningAlert(title: L10n.settingsDictionaryFileError, detail: error.localizedDescription)
        }
    }

    private func clearDictionary() {
        let count = SettingsManager.shared.userDictionary.words.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L10n.settingsDictionaryClearConfirm, count)
        alert.informativeText = L10n.settingsDictionaryClearDetail
        alert.addButton(withTitle: L10n.settingsDictionaryClearButton)
        alert.addButton(withTitle: L10n.commonCancel)
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsManager.shared.userDictionary.clear()
        dictionaryChanged(report: nil)
        rslog("user_dictionary_cleared")
    }

    private func showLearningAlert(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private static func exportDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func openGitHub() {
        if let url = URL(string: SettingsManager.githubURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showLogFile() {
        let path = ProductIdentity.logFilePath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } else {
            let alert = NSAlert()
            alert.messageText = L10n.logFileNotFound
            alert.informativeText = L10n.logFileEnableDebugFirst
            alert.runModal()
        }
    }

    private func sendLogFile() {
        let path = ProductIdentity.logFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            showLogFile() // покажет алерт
            return
        }

        let url = URL(fileURLWithPath: path)
        if let service = NSSharingService(named: .composeEmail) {
            service.perform(withItems: [
                "\(ProductIdentity.displayName) debug log" as NSString,
                url
            ])
        } else {
            // Fallback: показать в Finder
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }
}
