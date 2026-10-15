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
        return pages
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
        }
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
