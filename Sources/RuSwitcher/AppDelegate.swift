import AppKit
import ApplicationServices
import RuSwitcherAppSupport
import RuSwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let healthItemTag = 742
    private var conversionFeedback = ConversionFeedback()
    private var manualConversionLifecycle = ManualConversionLifecycle()
    private let feedbackNotice = FeedbackNoticeController()
    private var learningUndoAction: (() -> Void)?
    private var statusItem: NSStatusItem!
    private let focusedElementResolver = NativeFocusedEditableResolver()
    private lazy var keyboardMonitor = KeyboardMonitor(
        focusedElementResolver: focusedElementResolver
    )
    private lazy var textConverter = TextConverter(
        focusedElementResolver: focusedElementResolver
    )
    private lazy var replacementCoordinator = NativeReplacementCoordinator(
        reader: textContextReader,
        poster: textConverter
    )
    private lazy var automaticReplacementDriver = AutomaticReplacementDriver(coordinator: replacementCoordinator)
    private let languageModel = LanguageModelStore.bundled
    private lazy var personalLexicon = PersonalLexiconObserver(
        store: SettingsManager.shared.personalLexicon, dictionary: SettingsManager.shared.userDictionary,
        base: languageModel, resolver: focusedElementResolver
    )
    private lazy var textContextReader = FocusedTextContextReader(
        focusedElementResolver: focusedElementResolver
    )
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var updateCheckTimer: Timer?   // периодическая авто-проверка обновлений, пока приложение работает
    private var sessionResumeWorkItem: DispatchWorkItem?
    private var tapReconfigureWorkItem: DispatchWorkItem?
    private var lastSessionRecoveryAt = Date.distantPast
    private var monitoringActive = false
    private var siblingMonitoringStarted = false
    private var siblingApplications = SiblingApplicationTracker(
        ownProcessID: ProcessInfo.processInfo.processIdentifier,
        ownBundleID: ProductIdentity.bundleIdentifier
    )
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом
    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsManager.shared.migrateAdaptiveRulesIfNeeded()
        sanitizeAdaptiveRules()
        startSiblingApplicationMonitoring()
        if languageModel != nil {
            rslog("engine_v3_available")
        } else {
            rslog("engine_v3_unavailable")
        }
        if hasSiblingRuSwitcherInstance() {
            rslog("sibling_ruswitcher_instance_detected")
        }
        setupStatusItem()
        setupSettingsCallbacks()
        registerWorkspaceRecoveryObservers()
        syncLoginItem()
        runPermissionWizard()
        UpdateChecker.checkOnLaunch()
        // Периодическая авто-проверка обновлений, пока приложение работает (не только на старте).
        // Тикает каждые 6ч; сам запрос к GitHub не чаще раза в сутки (троттл в UpdateChecker) и
        // уважает настройку «Автоматически проверять обновления» (её можно снять, чтобы отключить).
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.checkPeriodic() }
        }
    }

    private func registerWorkspaceRecoveryObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceSessionResumed(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceSessionResumed(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func workspaceSessionResumed(_ notification: Notification) {
        guard monitoringActive else { return }
        sessionResumeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.monitoringActive else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastSessionRecoveryAt) >= 1 else { return }
            self.lastSessionRecoveryAt = now
            self.refreshSiblingApplications()
            FrontmostApplicationTracker.shared.refresh()
            rslog("workspace_session_resumed")
            self.cancelDeferredManualLearning()
            self.cancelManualAttempt()
            self.lastAutoConverted = nil
            self.manualLearningCheckpoint = nil
            self.textConverter.clearState()
            self.focusedElementResolver.invalidate()
            self.reconfigureTap()
        }
        sessionResumeWorkItem = work
        // Wake and session-active notifications often arrive as one pair.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    #if RUSWITCH_TEST_HOST
    /// Native integration host entry point. It wires the same production monitor
    /// and replacement path without update checks, onboarding, or login-item UI.
    func startHIDProbeMonitoring() {
        SettingsManager.shared.migrateAdaptiveRulesIfNeeded()
        sanitizeAdaptiveRules()
        startSiblingApplicationMonitoring()
        setupStatusItem()
        setupSettingsCallbacks()
        startMonitoring(offerSetup: false)
    }

    var probeEventTapEnabled: Bool { keyboardMonitor.eventTapEnabled }
    var probeModelAvailable: Bool { languageModel != nil }
    var probeTargetProcessID: pid_t?

    func observeProbeCallbacks(_ observer: @escaping (KeyboardCallbackTiming) -> Void) {
        keyboardMonitor.onCallbackTiming = observer
    }
    #endif

    private func setupSettingsCallbacks() {
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            self?.cancelDeferredManualLearning()
            self?.invalidateConversionAttempts()
            self?.textConverter.clearState()
            self?.keyboardMonitor.markConverted()
            self?.rebuildMenu()
        }
        settingsController.onPerAppLayoutChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startPerAppLayout()
            } else {
                self.perAppLayoutManager.stop()
            }
        }
        settingsController.onLanguageChanged = { [weak self] in
            self?.rebuildMenu()
        }
        settingsController.onTriggerChanged = { [weak self] in
            self?.reconfigureTap()
        }
        settingsController.onAutoConvertChanged = { [weak self] _ in
            self?.rebuildMenu()  // синхронизировать галочку в меню
            self?.reconfigureTap() // active tap нужен для атомарной replay-транзакции
        }
        settingsController.onRemoteDesktopChanged = { [weak self] _ in
            self?.reconfigureTap()  // уровень tap зависит от режима
            self?.rebuildMenu()
        }
        settingsController.onCheckPermissions = { [weak self] in
            self?.runPermissionWizard(interactive: true)
        }
        settingsController.onCaretFlagChanged = { [weak self] _ in
            self?.rebuildMenu()          // синхронизировать галочку в меню
            self?.syncCaretIndicator()   // создать/снести индикатор + обновить гейт onUserInput
        }
        settingsController.onVocabularyChanged = { [weak self] in
            self?.personalLexicon.vocabularyChanged()
        }
        settingsController.onPersonalDataWillChange = { [weak self] in
            self?.cancelDeferredManualLearning()
            self?.invalidateConversionAttempts()
            self?.manualLearningCheckpoint = nil
            self?.lastAutoConverted = nil
            self?.learningUndoAction = nil
            self?.feedbackNotice.dismiss()
            self?.personalLexicon.flush()
        }
        settingsController.onPersonalDataWillExport = { [weak self] in self?.personalLexicon.flush() }
        settingsController.onAppearanceChanged = { [weak self] in self?.updateStatusIcon() }
        settingsController.onLearnedRulesRemoved = { [weak self] in
            self?.cancelDeferredManualLearning()
            self?.invalidateConversionAttempts()
            self?.manualLearningCheckpoint = nil
            self?.lastAutoConverted = nil
            self?.learningUndoAction = nil
            self?.feedbackNotice.dismiss()
            self?.textConverter.clearState()
        }
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    private struct AutoLearningEvent {
        let original: String
        let converted: String
        let appBundleID: String?
        let at: Date
    }

    private var lastAutoConverted: AutoLearningEvent?
    private struct ManualLearningChange {
        let original: String
        let converted: String
        let rule: ManualLearningReceipt
        let personalWord: PersonalLexiconRemovalReceipt?
    }
    private var manualLearningCheckpoint: ManualLearningChange?
    private var sessionNegativePairs: Set<String> = []
    private var deferredManualLearning = DeferredManualLearningGate()
    #if RUSWITCH_TEST_HOST
    private(set) var postedAutomaticReplacementCount = 0
    private(set) var verifiedAutomaticReplacementCount = 0
    var onProbeManualResult: ((ConversionAttemptResult, ConversionFeedback.Attempt) -> Void)?
    var probeLearningUndoAvailable: Bool { learningUndoAction != nil }
    #endif

    private func learningKey(original: String, converted: String, appBundleID: String?) -> String {
        [
            FrequentWordLexicon.normalize(original),
            FrequentWordLexicon.normalize(converted),
            appBundleID ?? "*",
        ].joined(separator: "\u{1f}")
    }

    private func learnFromUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 20 else { return }
        lastAutoConverted = nil
        let settings = SettingsManager.shared
        guard !settings.wordConversionPolicy.excludes(original: last.original, converted: last.converted) else { return }
        if let app = last.appBundleID,
           settings.isAdaptiveConfirmed(original: last.original, converted: last.converted, appBundleID: nil) {
            do {
                if let saved = try settings.saveApplicationException(
                    original: last.original, converted: last.converted, appBundleID: app
                ) {
                    showSavedLearning(saved, original: last.converted, converted: last.original,
                                      frontID: app, personalWord: nil)
                }
            } catch {
                feedbackNotice.show(message: L10n.learningSaveFailed)
                rslog("learning_save_failed")
            }
            return
        }
        sessionNegativePairs.insert(learningKey(
            original: last.original,
            converted: last.converted,
            appBundleID: last.appBundleID
        ))
        SettingsManager.shared.recordAdaptiveNegative(
            original: last.original,
            converted: last.converted,
            appBundleID: last.appBundleID
        )
        rslog("learning_negative")
    }

    private func reinforcePreviousCorrectionIfNeeded() {
        guard let last = lastAutoConverted else { return }
        lastAutoConverted = nil
        SettingsManager.shared.recordAdaptivePositive(
            original: last.original,
            converted: last.converted
        )
        rslog("learning_positive")
    }

    private func manualLearningIsEligible(
        original: String,
        converted: String,
        frontID: String?,
        logFailure: Bool
    ) -> Bool {
        let decision = ManualLearningPolicy.decision(
            original: original, converted: converted, appBundleID: frontID,
            ruleBook: SettingsManager.shared.adaptiveRuleBook, model: languageModel,
            neverConvert: SettingsManager.shared.deniedWordsSet
        )
        if decision == .ignore, logFailure { rslog("learning_ineligible_skipped") }
        return decision != .ignore
    }

    @discardableResult
    private func persistManualLearning(
        original: String,
        converted: String,
        frontID: String?
    ) -> Bool {
        let settings = SettingsManager.shared
        let saved: (ManualLearningSave, PersonalLexiconRemovalReceipt?)
        do {
            guard let result = try personalLexicon.withSerializedChanges({
                () throws -> (ManualLearningSave, PersonalLexiconRemovalReceipt?)? in
                guard let save = try settings.saveManualLearning(
                    original: original, converted: converted, appBundleID: frontID, model: languageModel
                ) else { return nil }
                do {
                    var removal: PersonalLexiconRemovalReceipt?
                    if case let .confirmation(source, _, _) = save.decision {
                        removal = try settings.personalLexicon.removeWithReceipt(
                            word: source, language: SmartTokenizer.languageHint(for: source) ?? "en"
                        )
                    }
                    return (save, removal)
                } catch {
                    _ = try? settings.undoManualLearning(save.receipt)
                    throw error
                }
            }) else {
                manualLearningCheckpoint = nil
                lastAutoConverted = nil
                return false
            }
            saved = result
        } catch {
            manualLearningCheckpoint = nil
            lastAutoConverted = nil
            feedbackNotice.show(message: L10n.learningSaveFailed)
            rslog("learning_save_failed")
            return false
        }
        showSavedLearning(saved.0, original: original, converted: converted,
                          frontID: frontID, personalWord: saved.1)
        return true
    }

    private func showSavedLearning(_ saved: ManualLearningSave, original: String, converted: String,
                                   frontID: String?, personalWord: PersonalLexiconRemovalReceipt?) {
        let change = ManualLearningChange(original: original, converted: converted,
                                          rule: saved.receipt, personalWord: personalWord)
        manualLearningCheckpoint = change
        learningUndoAction = { [weak self] in self?.undoLearning(change) }
        switch saved.decision {
        case .ignore:
            lastAutoConverted = nil
            rslog("learning_ineligible_skipped")
            return
        case .applicationException:
            // This is not a new positive pair. A following token must not
            // reinforce the deliberately rejected spelling globally.
            lastAutoConverted = nil
            feedbackNotice.show(message: L10n.learningExceptionSaved, undo: learningUndoAction)
            settingsController.refresh()
            rslog("learning_application_exception")
            return
        case let .confirmation(source, target, _):
            sessionNegativePairs.remove(learningKey(original: source, converted: target, appBundleID: frontID))
            lastAutoConverted = AutoLearningEvent(original: source, converted: target, appBundleID: frontID, at: Date())
            feedbackNotice.show(message: L10n.learningSaved, undo: learningUndoAction)
            settingsController.refresh()
            rslog("learning_confirmed")
            return
        }
    }

    private func undoLearning(_ change: ManualLearningChange) {
        let settings = SettingsManager.shared
        do {
            let result = try personalLexicon.withSerializedChanges {
                if let blocked = settings.validateLearningUndo(change.rule) { return blocked }
                if let word = change.personalWord,
                   let blocked = settings.personalLexicon.validateUndo(word) { return blocked }
                let result = try settings.undoManualLearning(change.rule)
                guard result == .undone else { return result }
                if let word = change.personalWord {
                    guard try settings.personalLexicon.undo(word) == .undone else {
                        throw PersonalDataStoreError.externalChange
                    }
                }
                return PersonalDataUndoResult.undone
            }
            feedbackNotice.show(message: result == .undone ? L10n.learningUndone : L10n.learningUndoConflict)
            rslog("learning_undo_finished")
        } catch {
            feedbackNotice.show(message: L10n.learningUndoFailed)
            rslog("learning_undo_failed")
        }
        learningUndoAction = nil
        manualLearningCheckpoint = nil
        lastAutoConverted = nil
        cancelDeferredManualLearning()
        settingsController.refresh()
    }

    private func stageDeferredManualLearning(frontID: String?) {
        guard let pair = textConverter.lastLearningPair,
              manualLearningIsEligible(
                original: pair.original,
                converted: pair.converted,
                frontID: frontID,
                logFailure: true
              ) else {
            lastAutoConverted = nil
            return
        }
        let generation = deferredManualLearning.stage(DeferredManualLearningCandidate(
            original: pair.original,
            converted: pair.converted,
            appBundleID: frontID
        ))
        lastAutoConverted = nil
        rslog("learning_pending")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.acceptDeferredManualLearning(expectedGeneration: generation)
        }
    }

    private func acceptDeferredManualLearning(expectedGeneration: UInt64) {
        guard let candidate = deferredManualLearning.accept(
            expectedGeneration: expectedGeneration
        ) else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == candidate.appBundleID,
              !AutoSwitchPolicy.secureInputActive else {
            rslog("learning_pending_cancelled")
            return
        }
        _ = persistManualLearning(
            original: candidate.original,
            converted: candidate.converted,
            frontID: candidate.appBundleID
        )
    }

    private func cancelDeferredManualLearning() {
        if deferredManualLearning.hasPendingCandidate {
            rslog("learning_pending_cancelled")
        }
        deferredManualLearning.cancel()
    }

    private func startPerAppLayout() {
        perAppLayoutManager.onLayoutRestored = { [weak self] in
            self?.keyboardMonitor.markConverted()
            self?.textConverter.clearState()
            self?.updateStatusIcon()
        }
        perAppLayoutManager.start()
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("login_item_sync")

        if wanted && status != .enabled {
            // Галочка стоит, но Login Item не активен — перерегистрируем
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            // Галочка снята, но Login Item активен — убираем
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    private func runPermissionWizard(interactive: Bool = false) {
        let acc = AXIsProcessTrusted()
        let inp = CGPreflightListenEventAccess()
        rslog("permissions_checked")

        if acc && inp {
            // Запоминаем что разрешения были даны
            SettingsManager.shared.permissionsWereGranted = true
            if !monitoringActive { startMonitoring() }
            // Ручная проверка из меню должна давать видимый отклик.
            if interactive { showPermissionsOKAlert() }
            return
        }

        // Проверяем: разрешения были раньше, а теперь сброшены (обновление)
        if SettingsManager.shared.permissionsWereGranted {
            rslog("Permissions were previously granted — reset detected after update")
            SettingsManager.shared.permissionsWereGranted = false
            showPermissionsResetAlert()
            return
        }

        // Первый запуск — обычный визард
        if acc {
            showStep_InputMonitoring()
            return
        }

        showStep_Accessibility()
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.permissionsOkTitle
        alert.informativeText = L10n.permissionsOkText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Уведомление о сбросе разрешений после обновления
    private func showPermissionsResetAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardPermissionsResetTitle
        alert.informativeText = L10n.wizardPermissionsResetText
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Сбрасываем старые записи через tccutil
        resetPermissions()

        // Запрашиваем заново
        showStep_Accessibility()
    }

    /// Сбрасывает старые записи разрешений для нашего bundle ID
    private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? ProductIdentity.bundleIdentifier
        rslog("tcc_reset_started")

        for service in ["Accessibility", "ListenEvent"] {
            let reset = Process()
            reset.launchPath = "/usr/bin/tccutil"
            reset.arguments = ["reset", service, bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }

        rslog("TCC entries reset done")
    }

    private func showStep_Accessibility() {
        // AXIsProcessTrustedWithOptions с prompt=true показывает системный диалог
        // и добавляет программу в список Accessibility автоматически
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    rslog("Accessibility granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.showStep_InputMonitoring()
                }
            }
        }
    }

    private func showStep_InputMonitoring() {
        // CGRequestListenEventAccess() показывает системный диалог и добавляет
        // программу в список Input Monitoring автоматически
        let preflightOK = CGPreflightListenEventAccess()
        rslog("input_monitoring_preflight")

        if preflightOK {
            // Уже есть — сразу запускаем
            SettingsManager.shared.permissionsWereGranted = true
            startMonitoring()
            return
        }

        rslog("Requesting access...")
        CGRequestListenEventAccess()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightListenEventAccess() {
                    rslog("Input Monitoring granted! Restarting...")
                    SettingsManager.shared.permissionsWereGranted = true
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.restartApp()
                }
            }
        }
    }

    private func restartApp() {
        rslog("application_restarting")
        AppRelauncher.relaunch()
    }

    // MARK: - Start Monitoring

    private func startMonitoring(offerSetup: Bool = true) {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil

        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                #if RUSWITCH_TEST_HOST
                if let target = self.probeTargetProcessID,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != target { return }
                #endif
                let attempt = self.conversionFeedback.begin(.manual)
                guard self.manualConversionLifecycle.begin(attempt) else {
                    self.recordManualResult(.refused(.busy), attempt: attempt)
                    return
                }
                guard SettingsManager.shared.autoSwitchEnabled else {
                    self.recordManualResult(.refused(.disabled), attempt: attempt)
                    return
                }
                self.cancelDeferredManualLearning()
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.recordManualResult(.switchedOnly, attempt: attempt)
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if AutoSwitchPolicy.secureInputActive {
                    self.recordManualResult(.refused(.secureInput), attempt: attempt)
                    rslog("trigger: blocked secure-input")
                    return
                }
                let editor = self.keyboardMonitor.manualEditorSnapshot()
                self.textConverter.convertSelectedText(
                    requireReadableSelection: !self.keyboardMonitor.hasManualToken,
                    isCurrent: { [weak self] in
                        guard let self, let editor,
                              let current = self.keyboardMonitor.manualEditorSnapshot() else { return false }
                        return self.manualConversionLifecycle.isCurrent(attempt)
                            && current.focus.processID == editor.focus.processID
                            && current.focus.bundleID == editor.focus.bundleID
                            && (editor.focus.identifier == nil || current.focus.identifier == editor.focus.identifier)
                            && current.sequence == editor.sequence
                            && current.editRevision == editor.editRevision
                    }
                ) { [weak self] outcome in
                    self?.finishManualTriggerAfterSelection(outcome, frontID: frontID, attempt: attempt)
                }
                return
            }
        ) {
            rslog("Event tap failed - will retry in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startMonitoring()
            }
            return
        }

        monitoringActive = true
        keyboardMonitor.onTokenCompleted = { [weak self] snapshot, proxy in
            self?.handleAutoConvert(snapshot, proxy: proxy) ?? .passThrough
        }
        keyboardMonitor.onTokenChanged = { [weak self] draft in
            guard draft.keys.count == 1 else { return }
            self?.focusedElementResolver.prefetch(processID: draft.focus.processID)
        }
        keyboardMonitor.onCorrectionEdited = { [weak self] in
            self?.learnFromUndo()
        }
        keyboardMonitor.onUserContinuedAfterConversion = { [weak self] in
            self?.manualLearningCheckpoint = nil
            guard let self, let generation = self.deferredManualLearning.pendingGeneration else { return }
            DispatchQueue.main.async { [weak self] in
                self?.acceptDeferredManualLearning(expectedGeneration: generation)
            }
        }
        keyboardMonitor.onManualConversionRejected = { [weak self] in
            self?.cancelDeferredManualLearning()
        }
        keyboardMonitor.onEditingInvalidated = { [weak self] in
            self?.cancelManualAttempt()
            self?.cancelDeferredManualLearning()
            self?.textConverter.clearState()
            self?.lastAutoConverted = nil
            self?.manualLearningCheckpoint = nil
            self?.focusedElementResolver.invalidate()
        }
        keyboardMonitor.onFrontmostProcessChanged = { [weak self] processID in
            self?.focusedElementResolver.prefetch(processID: processID)
        }
        keyboardMonitor.onUserInput = { [weak self] in self?.caretIndicator?.userTyped() }  // issue #10
        updateStatusIcon()        // сначала выставляем флаг меню-бара, пока индикатора ещё нет
        syncCaretIndicator()      // затем создаём индикатор — без стартового ложного «попа»
        // Страховка к issue #9: системное уведомление о смене раскладки ненадёжно
        // (особенно через удалённый стол — на той машине оно часто не доходит), поэтому
        // флаг «застревает». Постоянный лёгкий опрос держит иконку в синхроне с системой.
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }
        rslog("Monitoring started successfully")
        if let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            focusedElementResolver.prefetch(processID: processID)
        }

        if SettingsManager.shared.perAppLayout {
            startPerAppLayout()
        }

        // Предлагаем автозагрузку и автозамену при первом запуске (по разу)
        if offerSetup {
            offerLaunchAtLoginIfNeeded()
            offerAutoConvertIfNeeded()
        }
    }

    private func finishManualTriggerAfterSelection(
        _ selectionOutcome: SelectedTextConversionOutcome,
        frontID: String?,
        attempt: ConversionFeedback.Attempt
    ) {
        guard manualConversionLifecycle.isCurrent(attempt) else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontID else {
            recordManualResult(.refused(.editorChanged), attempt: attempt)
            return
        }
        switch selectionOutcome {
        case .converted:
            recordManualResult(.converted, attempt: attempt)
            finishManualConversion(
                frontID: frontID,
                targetLayoutID: textConverter.lastManualTargetLayoutID
            )
            return
        case .postedUnverified:
            recordManualResult(.unverified, attempt: attempt)
            return
        case let .blocked(reason):
            recordManualResult(.refused(reason), attempt: attempt)
            return
        case .failed:
            // A real selection has priority. If it could not be converted, do not
            // mutate a buffered token or switch layout behind that selection.
            recordManualResult(.refused(.verificationFailed), attempt: attempt)
            return
        case .none:
            break
        }

        let boundaryCount = keyboardMonitor.boundaryCount
        if keyboardMonitor.shouldReconvert, textConverter.canReconvert {
            guard let reconversion = textConverter.prepareReconversion(
                trailingSpaces: boundaryCount
            ), let snapshot = keyboardMonitor.manualEditorSnapshot() else {
                textConverter.cancelPendingReconversion()
                recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            submitManualReconversion(
                reconversion,
                snapshot: snapshot,
                frontID: frontID,
                attempt: attempt
            )
            return
        }
        if let snapshot = keyboardMonitor.manualTokenSnapshot(),
           let conversion = textConverter.prepareBufferedConversion(keys: snapshot.keys) {
            submitManualBufferedConversion(
                conversion,
                snapshot: snapshot,
                frontID: frontID,
                attempt: attempt
            )
            return
        }
        convertWordBeforeCaretOrSwitchLayout(frontID: frontID, attempt: attempt)
    }

    private func recordManualResult(_ result: ConversionAttemptResult, attempt: ConversionFeedback.Attempt) {
        manualConversionLifecycle.finish(attempt)
        guard conversionFeedback.record(result, for: attempt) else { return }
        #if RUSWITCH_TEST_HOST
        onProbeManualResult?(result, attempt)
        #endif
        switch result {
        case .refused, .unverified:
            feedbackNotice.show(message: L10n.conversionResult(result))
        case .converted, .kept, .switchedOnly:
            break
        }
    }

    private func cancelManualAttempt() {
        guard let attempt = manualConversionLifecycle.active else { return }
        recordManualResult(.refused(.editorChanged), attempt: attempt)
    }

    private func invalidateConversionAttempts() {
        cancelManualAttempt()
        conversionFeedback.invalidatePending()
    }

    /// One deferred retry when caret prep is busy (short AX verify / previous
    /// replace still settling). Retry only continues if focus identity, sequence
    /// and edit revision still match the attempt that saw `.busy` — a click into
    /// another field of the same app must cancel, not convert the wrong suffix.
    private func convertWordBeforeCaretOrSwitchLayout(
        frontID: String?,
        attempt: ConversionFeedback.Attempt,
        requiredEditor: ManualTokenSnapshot? = nil,
        allowBusyRetry: Bool = true
    ) {
        guard manualConversionLifecycle.isCurrent(attempt) else { return }
        guard !AutoSwitchPolicy.isDeniedApp(frontID) else {
            recordManualResult(.refused(.excludedApplication), attempt: attempt)
            return
        }
        guard let snapshot = keyboardMonitor.manualEditorSnapshot() else {
            recordManualResult(.refused(.fieldUnavailable), attempt: attempt)
            return
        }
        if let required = requiredEditor {
            guard snapshot.focus == required.focus,
                  snapshot.sequence == required.sequence,
                  snapshot.editRevision == required.editRevision else {
                rslog("manual_caret_word_retry_stale")
                recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
        }
        textConverter.prepareCaretWordConversion(focus: snapshot.focus) { [weak self] outcome in
            guard let self, self.manualConversionLifecycle.isCurrent(attempt) else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontID else {
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            switch Self.validatedCaretWordPreparationOutcome(
                outcome,
                expected: snapshot,
                current: self.keyboardMonitor.manualEditorSnapshot()
            ) {
            case .busy:
                guard allowBusyRetry else {
                    rslog("manual_caret_word_busy")
                    self.recordManualResult(.refused(.busy), attempt: attempt)
                    return
                }
                let frozen = snapshot
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.convertWordBeforeCaretOrSwitchLayout(
                        frontID: frontID,
                        attempt: attempt,
                        requiredEditor: frozen,
                        allowBusyRetry: false
                    )
                }
            case .noCandidate:
                self.finishManualSwitchOnly()
                self.recordManualResult(.switchedOnly, attempt: attempt)
            case let .blocked(reason):
                self.recordManualResult(.refused(reason), attempt: attempt)
            case let .conversion(conversion):
                self.submitManualCaretWordConversion(
                    conversion,
                    snapshot: snapshot,
                    frontID: frontID,
                    attempt: attempt
                )
            }
        }
    }

    static func validatedCaretWordPreparationOutcome(
        _ outcome: CaretWordPreparationOutcome,
        expected: ManualTokenSnapshot,
        current: ManualTokenSnapshot?
    ) -> CaretWordPreparationOutcome {
        guard let current,
              current.focus == expected.focus,
              current.sequence == expected.sequence,
              current.editRevision == expected.editRevision else {
            rslog("manual_caret_word_stale_after_prep")
            return .blocked(.editorChanged)
        }
        return outcome
    }

    private func finishManualSwitchOnly() {
        textConverter.clearState()
        keyboardMonitor.markConverted()
        applyTargetLayout(nil, synchronizeQueuedKeys: true)
    }

    private func submitManualBufferedConversion(
        _ conversion: BufferedManualConversion,
        snapshot: ManualTokenSnapshot,
        frontID: String?,
        attempt: ConversionFeedback.Attempt
    ) {
        let hadCurrentToken = !keyboardMonitor.currentWordKeys.isEmpty
        let targetLayoutID = oppositeLayoutID(for: conversion.sourceLayoutID)
        let transaction = ConversionTransaction(
            original: conversion.original,
            replacement: conversion.replacement,
            boundary: snapshot.boundary,
            focus: snapshot.focus,
            sourceLayoutID: conversion.sourceLayoutID,
            targetLayoutID: targetLayoutID,
            sequence: snapshot.sequence,
            editRevision: snapshot.editRevision,
            expectedOriginalSuffix: conversion.original + snapshot.boundary.replayText,
            automatic: false
        )
        guard let stagedSequence = keyboardMonitor.stageManualConversion(
            expectedSequence: snapshot.sequence,
            expectedRevision: snapshot.editRevision,
            hadCurrentToken: hadCurrentToken
        ) else {
            recordManualResult(.refused(.editorChanged), attempt: attempt)
            return
        }
        textConverter.replaceFocusedSuffix(
            expected: transaction.expectedOriginalSuffix,
            replacement: transaction.insertedText,
            focus: snapshot.focus,
            targetLayoutID: targetLayoutID,
            isCurrent: { [weak self] in
                self?.manualConversionLifecycle.isCurrent(attempt) == true
                && self?.keyboardMonitor.isStagedCompletionCurrent(
                    expectedSequence: stagedSequence
                ) == true
            }
        ) { [weak self] outcome in
            guard let self else { return }
            guard self.manualConversionLifecycle.isCurrent(attempt) else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontID else {
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            guard self.keyboardMonitor.isStagedCompletionCurrent(
                expectedSequence: stagedSequence
            ) else {
                self.textConverter.cancelPendingReconversion()
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            switch outcome {
            case let .blocked(reason):
                self.recordManualResult(.refused(reason), attempt: attempt)
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
            case .verified:
                self.recordManualResult(.converted, attempt: attempt)
                self.textConverter.recordPostedManualBuffer(conversion, transaction: transaction)
                self.finishManualConversion(frontID: frontID, targetLayoutID: targetLayoutID)
            case .postedUnverified:
                self.recordManualResult(.unverified, attempt: attempt)
                self.textConverter.recordPostedManualBuffer(conversion, transaction: transaction)
                self.keyboardMonitor.finishUnverifiedPostedConversion(
                    expectedSequence: stagedSequence
                )
                self.finishManualConversion(
                    frontID: frontID,
                    targetLayoutID: targetLayoutID,
                    allowLearning: false
                )
                self.stageDeferredManualLearning(frontID: frontID)
            case .failed:
                self.recordManualResult(.refused(.verificationFailed), attempt: attempt)
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
            }
        }
    }

    private func submitManualReconversion(
        _ reconversion: BufferedManualReconversion,
        snapshot: ManualTokenSnapshot,
        frontID: String?,
        attempt: ConversionFeedback.Attempt
    ) {
        let focus = reconversion.focus ?? snapshot.focus
        let transaction = ConversionTransaction(
            original: reconversion.current,
            replacement: reconversion.replacement,
            boundary: .punctuation(""),
            focus: focus,
            sourceLayoutID: LayoutSwitcher.currentLayoutID(),
            targetLayoutID: reconversion.targetLayoutID,
            sequence: snapshot.sequence,
            editRevision: snapshot.editRevision,
            expectedOriginalSuffix: reconversion.current,
            automatic: false
        )
        guard let stagedSequence = keyboardMonitor.stageManualConversion(
            expectedSequence: snapshot.sequence,
            expectedRevision: snapshot.editRevision,
            hadCurrentToken: false
        ) else {
            textConverter.cancelPendingReconversion()
            recordManualResult(.refused(.editorChanged), attempt: attempt)
            return
        }
        textConverter.replaceFocusedSuffix(
            expected: reconversion.current,
            replacement: reconversion.replacement,
            focus: focus,
            targetLayoutID: reconversion.targetLayoutID,
            expectedCaretLocation: reconversion.expectedCaretLocation,
            isCurrent: { [weak self] in
                self?.manualConversionLifecycle.isCurrent(attempt) == true
                && self?.keyboardMonitor.isStagedCompletionCurrent(
                    expectedSequence: stagedSequence
                ) == true
            }
        ) { [weak self] outcome in
            guard let self else { return }
            guard self.manualConversionLifecycle.isCurrent(attempt) else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontID else {
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            guard self.keyboardMonitor.isStagedCompletionCurrent(
                expectedSequence: stagedSequence
            ) else {
                self.textConverter.cancelPendingReconversion()
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            switch outcome {
            case let .blocked(reason):
                self.recordManualResult(.refused(reason), attempt: attempt)
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
            case .verified:
                self.recordManualResult(.converted, attempt: attempt)
                self.finishManualReconversion(
                    reconversion,
                    transaction: transaction,
                    allowLearning: true
                )
            case .postedUnverified:
                self.recordManualResult(.unverified, attempt: attempt)
                self.keyboardMonitor.finishUnverifiedPostedConversion(
                    expectedSequence: stagedSequence
                )
                self.finishManualReconversion(
                    reconversion,
                    transaction: transaction,
                    allowLearning: false
                )
            case .failed:
                self.recordManualResult(.refused(.verificationFailed), attempt: attempt)
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
            }
        }
    }

    private func submitManualCaretWordConversion(
        _ conversion: CaretWordConversion,
        snapshot: ManualTokenSnapshot,
        frontID: String?,
        attempt: ConversionFeedback.Attempt
    ) {
        let trailing = String(conversion.expectedSuffix.dropFirst(conversion.original.count))
        let boundary: InputBoundary = trailing.isEmpty
            ? .punctuation("")
            : .space(count: trailing.count)
        let resolvedFocus = FocusedElementIdentity(
            processID: snapshot.focus.processID,
            bundleID: snapshot.focus.bundleID,
            identifier: conversion.elementIdentifier
        )
        let transaction = ConversionTransaction(
            original: conversion.original,
            replacement: conversion.replacement,
            boundary: boundary,
            focus: resolvedFocus,
            sourceLayoutID: conversion.sourceLayoutID,
            targetLayoutID: conversion.targetLayoutID,
            sequence: snapshot.sequence,
            editRevision: snapshot.editRevision,
            expectedOriginalSuffix: conversion.expectedSuffix,
            automatic: false
        )
        guard let stagedSequence = keyboardMonitor.stageVerifiedCaretConversion(
            expectedSequence: snapshot.sequence,
            expectedRevision: snapshot.editRevision
        ) else {
            recordManualResult(.refused(.editorChanged), attempt: attempt)
            return
        }
        textConverter.replaceFocusedSuffix(
            expected: transaction.expectedOriginalSuffix,
            replacement: transaction.insertedText,
            focus: resolvedFocus,
            targetLayoutID: conversion.targetLayoutID,
            expectedCaretLocation: conversion.caretLocation,
            isCurrent: { [weak self] in
                self?.manualConversionLifecycle.isCurrent(attempt) == true
                && self?.keyboardMonitor.isStagedCompletionCurrent(
                    expectedSequence: stagedSequence
                ) == true
            }
        ) { [weak self] outcome in
            guard let self else { return }
            guard self.manualConversionLifecycle.isCurrent(attempt) else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontID else {
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            guard self.keyboardMonitor.isStagedCompletionCurrent(
                expectedSequence: stagedSequence
            ) else {
                self.textConverter.cancelPendingReconversion()
                self.recordManualResult(.refused(.editorChanged), attempt: attempt)
                return
            }
            switch outcome {
            case let .blocked(reason):
                self.recordManualResult(.refused(reason), attempt: attempt)
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
            case .verified:
                self.recordManualResult(.converted, attempt: attempt)
                self.textConverter.recordPostedCaretWord(conversion, transaction: transaction)
                self.finishManualConversion(
                    frontID: frontID,
                    targetLayoutID: conversion.targetLayoutID
                )
            case .postedUnverified:
                self.recordManualResult(.unverified, attempt: attempt)
                self.textConverter.recordPostedCaretWord(conversion, transaction: transaction)
                self.keyboardMonitor.finishUnverifiedPostedConversion(
                    expectedSequence: stagedSequence
                )
                self.finishManualConversion(
                    frontID: frontID,
                    targetLayoutID: conversion.targetLayoutID,
                    allowLearning: false
                )
                self.stageDeferredManualLearning(frontID: frontID)
            case .failed:
                self.recordManualResult(.refused(.verificationFailed), attempt: attempt)
                self.textConverter.cancelPendingReconversion()
                self.keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
            }
        }
    }

    private func finishManualReconversion(
        _ reconversion: BufferedManualReconversion,
        transaction: ConversionTransaction,
        allowLearning: Bool
    ) {
        textConverter.recordPostedReconversion(reconversion, transaction: transaction)
        keyboardMonitor.markConverted()
        applyTargetLayout(reconversion.targetLayoutID, synchronizeQueuedKeys: true)
        let source = reconversion.current.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = reconversion.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = SettingsManager.shared
        guard !settings.wordConversionPolicy.excludes(original: source, converted: target) else {
            manualLearningCheckpoint = nil
            lastAutoConverted = nil
            cancelDeferredManualLearning()
            return
        }
        let core = { FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: $0)) }
        let same = { core($0) == core($1) }
        guard let typed = textConverter.lastLearningPair?.original else {
            lastAutoConverted = nil
            return
        }
        guard same(target, typed) else {
            // Converting the typed word again is the user's final choice.
            if allowLearning {
                _ = persistManualLearning(original: source, converted: target, frontID: transaction.focus.bundleID)
            } else {
                lastAutoConverted = nil
            }
            return
        }
        guard allowLearning else {
            lastAutoConverted = nil
            return
        }
        // Back to what was typed: the conversion was a mistake, not a lesson.
        if let checkpoint = manualLearningCheckpoint, same(checkpoint.original, target), same(checkpoint.converted, source) {
            undoLearning(checkpoint)
            rslog("learning_manual_reverted")
        } else if let last = lastAutoConverted,
                  last.appBundleID == transaction.focus.bundleID,
                  same(source, last.converted), same(target, last.original) {
            learnFromUndo()
        } else if settings.isAdaptiveConfirmed(original: source, converted: target, appBundleID: nil)
                    || settings.isAdaptiveConfirmed(original: target, converted: source, appBundleID: nil) {
            // Reverting a learned word later, after the user moved on, is a
            // decision about that learned pair; an unknown pair learns nothing.
            _ = persistManualLearning(original: source, converted: target, frontID: transaction.focus.bundleID)
        } else {
            lastAutoConverted = nil
        }
    }

    private func finishManualConversion(
        frontID: String?,
        targetLayoutID: String?,
        allowLearning: Bool = true
    ) {
        keyboardMonitor.markConverted()
        applyTargetLayout(targetLayoutID, synchronizeQueuedKeys: true)
        guard allowLearning else {
            lastAutoConverted = nil
            return
        }
        guard let pair = textConverter.lastLearningPair else {
            lastAutoConverted = nil
            return
        }
        _ = persistManualLearning(
            original: pair.original,
            converted: pair.converted,
            frontID: frontID
        )
    }

    private func sanitizeAdaptiveRules() {
        let removed = SettingsManager.shared.removeAdaptiveConfirmedPairs {
            [languageModel] original, converted in
            ManualLearningPolicy.isLikelyReverseConversion(
                original: original,
                converted: converted,
                model: languageModel
            )
        }
        if removed > 0 {
            rslog("learning_reverse_rules_removed")
        }
    }

    /// Smart auto-conversion runs synchronously while the active event tap owns the
    /// boundary. It only consumes a space after the complete replacement transaction
    /// has been posted; every early exit passes the original event through unchanged.
    private func layoutLanguages(
        keys: [TypedKey],
        pair: ReconciledKeyText,
        sourceLayoutID: String?
    ) -> (current: String, opposite: String)? {
        if keys.allSatisfy({ $0.char != nil }) {
            let typedIsCyrillic = pair.original.unicodeScalars.contains {
                (0x0400...0x04FF).contains($0.value)
            }
            return typedIsCyrillic ? ("ru", "en") : ("en", "ru")
        }
        guard let sourceLayoutID,
              let languages = LayoutSwitcher.languagePair(sourceLayoutID: sourceLayoutID) else { return nil }
        return pair.sourceWasOpposite
            ? (current: languages.opposite, opposite: languages.current)
            : languages
    }

    private func handleAutoConvert(
        _ snapshot: TokenSnapshot,
        proxy: CGEventTapProxy
    ) -> TokenHandlingResult {
        #if RUSWITCH_TEST_HOST
        if let target = probeTargetProcessID, snapshot.focus.processID != target { return .passThrough }
        #endif
        CallbackPhaseProbe.mark("auto.start")
        defer { CallbackPhaseProbe.mark("auto.end") }
        rslog("auto: fired")
        // Reaching the next completed token without Backspace/Undo is a soft
        // positive signal for the previous correction.
        reinforcePreviousCorrectionIfNeeded()
        manualLearningCheckpoint = nil
        guard SettingsManager.shared.autoSwitchEnabled else { rslog("auto: bail master-off"); return .passThrough }
        guard SettingsManager.shared.autoConvert else { rslog("auto: bail flag-off"); return .passThrough }
        let attempt = conversionFeedback.begin(.automatic)
        guard !AutoSwitchPolicy.secureInputActive else {
            conversionFeedback.record(.refused(.secureInput), for: attempt)
            rslog("auto: bail secure-input"); return .passThrough
        }
        let frontID = FrontmostApplicationTracker.shared.bundleID
        let frontPID = FrontmostApplicationTracker.shared.processID
        // Удалёнка: НЕ выходим сразу — прогоняем детектор по своему (чистому) буферу, и при
        // «не той раскладке» переключаем СВОЮ раскладку (конверсию делает инстанс на той стороне).
        let deferToRemote = SettingsManager.shared.remoteDesktopMode && AutoSwitchPolicy.isRemoteDesktopClient(frontID)
        if AutoSwitchPolicy.isDeniedApp(frontID) {
            conversionFeedback.record(.refused(.excludedApplication), for: attempt)
            rslog("auto_blocked_denied_app"); return .passThrough
        }
        guard snapshot.focus.bundleID == frontID, snapshot.focus.processID == frontPID else {
            conversionFeedback.record(.refused(.editorChanged), for: attempt)
            rslog("auto: bail focus-changed"); return .passThrough
        }
        CallbackPhaseProbe.mark("auto.gates")

        let keys = snapshot.keys
        guard !keys.isEmpty else { rslog("auto: bail empty-keys"); return .passThrough }
        guard let pair = DynamicKeyMapping.convertKeys(keys) else {
            conversionFeedback.record(.refused(.unsupportedLayout), for: attempt)
            rslog("auto: bail convertKeys-nil"); return .passThrough
        }
        CallbackPhaseProbe.mark("auto.keys")
        // Язык для детектора. Для проброшенного через удалёнку текста (все символы — char)
        // направление определяем по СКРИПТУ набранного, а не по раскладке офисной машины:
        // на офисе раскладка может не соответствовать тому, что напечатали на контроллере,
        // и тогда decide ошибочно даёт keep (это и есть «авто в удалёнке не работает»).
        let langs = layoutLanguages(
            keys: keys,
            pair: pair,
            sourceLayoutID: snapshot.sourceLayoutID
        )
        CallbackPhaseProbe.mark("auto.languages")
        let policy = AutoConvertPolicy(
            neverConvert: SettingsManager.shared.deniedWordsSet,
            alwaysConvert: SettingsManager.shared.alwaysConvertWordsSet
        )
        let plan = AutomaticConversionPlanner.prepare(
            snapshot: snapshot, original: pair.original, converted: pair.converted,
            currentLanguage: langs?.current, targetLanguage: langs?.opposite,
            targetLayoutID: deferToRemote ? nil : (
                pair.sourceWasOpposite ? snapshot.sourceLayoutID : oppositeLayoutID(for: snapshot.sourceLayoutID)
            ),
            policy: policy,
            allowUnavailablePost: SettingsManager.shared.axlessConversion,
            adaptiveBias: { original, converted in
                // The reverse-conversion check costs more than the rule lookup,
                // and nearly every candidate has no rule.
                let learned = SettingsManager.shared.adaptiveBias(
                    original: original, converted: converted, appBundleID: frontID
                )
                let persisted = learned == 0 || ManualLearningPolicy.isLikelyReverseConversion(
                    original: original, converted: converted, model: self.languageModel
                ) ? 0 : learned
                let sessionPenalty = self.sessionNegativePairs.contains(self.learningKey(
                    original: original, converted: converted, appBundleID: frontID
                )) ? -12.0 : 0.0
                return persisted + sessionPenalty
            },
            isConfirmed: { original, converted in
                SettingsManager.shared.isAdaptiveConfirmed(
                    original: original, converted: converted, appBundleID: frontID
                ) && !ManualLearningPolicy.isLikelyReverseConversion(
                    original: original, converted: converted, model: self.languageModel
                )
            },
            model: personalLexicon.model
        )
        CallbackPhaseProbe.mark("auto.decision")
        rslog("auto_decision_completed")
        let request: ReplacementRequest
        switch plan {
        case let .keep(handling, evaluation, refusal):
            conversionFeedback.record(refusal.map(ConversionAttemptResult.refused)
                ?? ConversionAttemptResult(keptBecause: evaluation?.decision.reason), for: attempt)
            rslog("auto_kept")
            rslogDecision(evaluation?.decision.reason)
            // A plain word typed and left alone is a sighting for the personal
            // lexicon, except when editing state or a user rule decided it.
            if !deferToRemote, let langs, let reason = evaluation?.decision.reason,
               reason != .blockedEditing, reason != .blockedNever, reason != .blockedLearned,
               SettingsManager.shared.personalLexiconEnabled {
                personalLexicon.observe(typed: pair.original, language: langs.current, focus: snapshot.focus)
            }
            return handling
        case let .replace(prepared, evaluation):
            rslog("auto_replacement_requested")
            rslogDecision(evaluation.decision.reason)
            request = prepared
        }
        guard let langs else { return .passThrough }
        let targetLang = langs.opposite
        let transaction = request.transaction

        if deferToRemote {
            conversionFeedback.record(.switchedOnly, for: attempt)
            // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам.
            // Здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже в правильной.
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            rslog("auto: local layout switched, conversion handled by controlled instance")
            return TokenHandlingResult(
                consumeBoundary: false,
                resolvedText: transaction.replacement,
                resolvedLanguage: targetLang,
                wasConverted: true
            )
        }

        let stagedSequence = snapshot.sequence &+ 1
        let submission = automaticReplacementDriver.submit(
            request,
            sourceLanguage: langs.current,
            targetLanguage: targetLang,
            switchLayout: { targetID in
                self.applyTargetLayout(targetID, synchronizeQueuedKeys: Set([langs.current, targetLang]) == ["en", "ru"])
            }
        ) { [weak self] outcome in
            self?.finishAutomaticReplacement(
                outcome: outcome,
                transaction: transaction,
                replacement: transaction.replacement,
                targetLanguage: targetLang,
                appBundleID: frontID,
                stagedSequence: stagedSequence,
                attempt: attempt
            )
        }
        conversionFeedback.record(ConversionAttemptResult(outcome: submission.outcome), for: attempt)
        if !submission.isNewPost { logReplacementOutcome(submission.outcome) }
        if submission.isNewPost {
            #if RUSWITCH_TEST_HOST
            postedAutomaticReplacementCount += 1
            #endif
            // The posted pair is immediately available to the explicit manual
            // trigger. This prevents stale physical keys from converting the
            // already-corrected word to the same text again while AX verifies it.
            textConverter.recordCommittedTransaction(transaction)
        }
        return submission.handling
    }

    /// Outcomes are static names only; they say why a conversion did not land.
    private func logReplacementOutcome(_ outcome: ReplacementOutcome) {
        switch outcome {
        case .verified: rslog("auto_posted_verified")
        case .postedUnverified: rslog("auto_posted_unverified")
        case .switchedOnly: rslog("auto_switched_only")
        case .blocked(.invalidFocus): rslog("auto_blocked_invalid_focus")
        case .blocked(.staleRevision): rslog("auto_blocked_stale_revision")
        case .blocked(.expectedSuffixMismatch): rslog("auto_blocked_suffix_mismatch")
        case .blocked(.contextUnavailable): rslog("auto_blocked_ax_unavailable")
        case .blocked(.duplicateTransaction): rslog("auto_blocked_duplicate")
        case .blocked(.secureInput): rslog("auto_blocked_secure_input")
        case .blocked(.deniedApplication): rslog("auto_blocked_denied_app")
        case .blocked(.ambiguousDeletion): rslog("auto_blocked_ambiguous_deletion")
        case .failed(.eventPostFailed): rslog("auto_failed_post")
        case .failed(.verificationMismatch): rslog("auto_failed_verification")
        }
    }

    private func finishAutomaticReplacement(
        outcome: ReplacementOutcome,
        transaction: ConversionTransaction,
        replacement: String,
        targetLanguage: String,
        appBundleID: String?,
        stagedSequence: UInt64,
        attempt: ConversionFeedback.Attempt
    ) {
        logReplacementOutcome(outcome)
        let completion = AutomaticReplacementDriver.completion(
            for: outcome, transaction: transaction, state: keyboardMonitor.automaticReplacementState()
        )
        switch completion {
        case .confirm:
            guard keyboardMonitor.confirmStagedConversion(
                text: replacement,
                language: targetLanguage,
                expectedSequence: stagedSequence
            ) else { return }
            conversionFeedback.record(.converted, for: attempt)
            #if RUSWITCH_TEST_HOST
            verifiedAutomaticReplacementCount += 1
            #endif
            textConverter.recordCommittedTransaction(transaction)
            lastAutoConverted = AutoLearningEvent(
                original: transaction.original,
                converted: replacement,
                appBundleID: appBundleID,
                at: Date()
            )
        case .retainUnverified:
            // Post already succeeded and layout already switched. AX only failed
            // to read the result back — do not undo the staged conversion.
            guard keyboardMonitor.isStagedCompletionCurrent(
                expectedSequence: stagedSequence
            ) else { return }
            conversionFeedback.record(.unverified, for: attempt)
            keyboardMonitor.finishUnverifiedPostedConversion(expectedSequence: stagedSequence)
        case .invalidate:
            conversionFeedback.record(ConversionAttemptResult(outcome: outcome), for: attempt)
            textConverter.discardTransactionIfCurrent(transaction)
            keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
        case .discard:
            conversionFeedback.record(.unverified, for: attempt)
            textConverter.discardTransactionIfCurrent(transaction)
            keyboardMonitor.invalidateStagedCompletion(expectedSequence: stagedSequence)
        case .ignore:
            break
        }
    }

    private func applyTargetLayout(_ targetLayoutID: String?, synchronizeQueuedKeys: Bool) {
        if let targetLayoutID {
            let switched = LayoutSwitcher.switchTo(layoutID: targetLayoutID)
            CallbackPhaseProbe.mark("layout.selected")
            if switched, synchronizeQueuedKeys, !SettingsManager.shared.remoteDesktopMode {
                keyboardMonitor.recordLayoutSwitch(
                    targetLayoutID: targetLayoutID, completedAt: DispatchTime.now().uptimeNanoseconds
                )
            }
        } else {
            let previousLayoutID = LayoutSwitcher.currentLayoutID()
            LayoutSwitcher.switchToOpposite()
            let selectedLayoutID = LayoutSwitcher.currentLayoutID()
            if synchronizeQueuedKeys, !SettingsManager.shared.remoteDesktopMode,
               !selectedLayoutID.isEmpty, selectedLayoutID != previousLayoutID {
                keyboardMonitor.recordLayoutSwitch(
                    targetLayoutID: selectedLayoutID, completedAt: DispatchTime.now().uptimeNanoseconds
                )
            }
        }
        // The icon is cosmetic; redrawing it after the callback returns keeps
        // the event tap free. The layout itself switched synchronously above.
        DispatchQueue.main.async { [weak self] in self?.updateStatusIcon() }
    }

    private func oppositeLayoutID(for sourceLayoutID: String?) -> String? {
        guard let sourceLayoutID else { return nil }
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let id1 = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        return sourceLayoutID == id1 ? id2 : id1
    }

    /// Предлагает включить автозагрузку при первом запуске (один раз)
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.launchAtLoginAsked else { return }
        settings.launchAtLoginAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardLaunchAtLoginTitle
        alert.informativeText = L10n.wizardLaunchAtLoginText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            settings.launchAtLogin = true
            rslog("User enabled launch at login")
        } else {
            rslog("User declined launch at login")
        }
    }

    /// Предлагает включить автозамену при первом запуске (один раз). Фича OFF по умолчанию,
    /// поэтому без явного предложения пользователь о ней не узнает.
    private func offerAutoConvertIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.autoConvertOffered else { return }
        settings.autoConvertOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.onboardAutoConvertTitle
        alert.informativeText = L10n.onboardAutoConvertText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        if alert.runModal() == .alertFirstButtonReturn {
            settings.autoConvert = true
            rebuildMenu()  // синхронизировать галочку «Автоматическая конверсия» в меню
            rslog("User enabled auto-convert at onboarding")
        } else {
            rslog("User declined auto-convert at onboarding")
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        // issue #9: иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии. Слушаем системное
        // распределённое уведомление о смене источника ввода.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения глобусом 🌐 меняется с задержкой до нескольких секунд
        // (ждёт пробуждения или 2-секундного опроса). deliverImmediately обновляет флаг сразу.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemInputSourceChanged() {
        updateStatusIcon()
        keyboardMonitor.soundArmed = true  // issue #7: следующая буква даст звук раскладки
    }

    /// Собирает меню статус-бара. Вызывается заново при смене языка интерфейса,
    /// иначе пункты меню остаются на старом языке.
    private func rebuildMenu() {
        statusItem.menu = makeStatusMenu()
        rslog("menu_rebuilt")
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        populateStatusMenu(menu)
        menu.delegate = self
        return menu
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let health = NSMenuItem(title: autoConversionHealthText(), action: nil, keyEquivalent: "")
        health.tag = Self.healthItemTag
        menu.addItem(health)
        let last = conversionFeedback.latest
        let title = last.map {
            let prefix = $0.attempt.source == .manual ? L10n.menuLastManual : L10n.menuLastAutomatic
            let time = DateFormatter.localizedString(from: $0.at, dateStyle: .none, timeStyle: .short)
            return "\(time)  " + String(format: prefix, L10n.conversionResult($0.result))
        } ?? L10n.menuNoAttempts
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        @discardableResult
        func command(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        command(SettingsManager.shared.autoSwitchEnabled ? L10n.menuPause : L10n.menuResume,
                #selector(toggleAutoSwitch))
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        if let app, let bundleID, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let title = SettingsManager.shared.deniedApps.contains(bundleID)
                ? L10n.menuEnableCurrentApp : L10n.menuDisableCurrentApp
            command(String(format: title, app.localizedName ?? bundleID), #selector(toggleCurrentApplication))
                .representedObject = bundleID
        } else {
            menu.addItem(NSMenuItem(title: L10n.menuNoCurrentApp, action: nil, keyEquivalent: ""))
        }
        command(L10n.menuSettings, #selector(openSettings), key: ",")
        command(L10n.menuDictionary, #selector(openDictionary))
        if learningUndoAction != nil {
            command(L10n.learningUndo, #selector(undoLearningFromMenu))
        }
        menu.addItem(.separator())
        let layouts = NSMenuItem(title: L10n.menuLayouts, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for item in layoutMenuItems() { submenu.addItem(item) }
        layouts.submenu = submenu
        menu.addItem(layouts)
        menu.addItem(.separator())
        command(L10n.menuQuit, #selector(quit), key: "q")
    }

    // MARK: - Layout list in menu

    /// Метка пунктов-раскладок, чтобы находить и обновлять их группу в меню.
    private static let layoutItemTag = 741

    /// Пункты списка раскладок: «флаг + локализованное имя», галочка на текущей.
    private func layoutMenuItems() -> [NSMenuItem] {
        let currentID = LayoutSwitcher.currentLayoutID()
        return LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            let badge = LayoutSwitcher.languageCode(source).map(Self.flagBadge(forLanguage:))
            let title = [badge, LayoutSwitcher.sourceName(source)].compactMap { $0 }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == currentID) ? .on : .off
            item.tag = Self.layoutItemTag
            return item
        }
    }

    /// Пересобирает группу раскладок при каждом открытии меню: состав и галочка должны
    /// отражать систему на момент клика (раскладки добавляют/удаляют в настройках ОС,
    /// а текущую меняют и мимо нас — системным хоткеем).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshSiblingApplications()
        populateStatusMenu(menu)
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным — как при per-app restore.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let flag = flagForCurrentLayout()
        // Каретку дёргаем ТОЛЬКО при реальной смене раскладки: updateStatusIcon зовётся ещё и
        // 2-секундным опросом-страховкой, иначе флаг у каретки выскакивал бы каждые 2с.
        // Сравниваем по флагу-идентичности, а не по title — в монохромном режиме title пуст.
        let changed = lastFlagShown != flag
        lastFlagShown = flag
        if SettingsManager.shared.monochromeIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = badgeImage(for: currentBadgeLabel())
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = flag
        }
        if changed { caretIndicator?.layoutChanged() }
    }

    private func hasSiblingRuSwitcherInstance() -> Bool {
        siblingApplications.hasSibling
    }

    private func startSiblingApplicationMonitoring() {
        guard !siblingMonitoringStarted else { return }
        siblingMonitoringStarted = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(siblingApplicationChanged(_:)), name: name, object: nil)
        }
        refreshSiblingApplications()
    }

    private func refreshSiblingApplications() {
        siblingApplications.replace(with: NSWorkspace.shared.runningApplications.map(Self.siblingSnapshot))
    }

    private static func siblingSnapshot(_ application: NSRunningApplication) -> SiblingApplicationTracker.Application {
        .init(processID: application.processIdentifier, bundleID: application.bundleIdentifier, name: application.localizedName)
    }

    @objc private func siblingApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if notification.name == NSWorkspace.didTerminateApplicationNotification {
            _ = siblingApplications.terminated(processID: application.processIdentifier)
        } else {
            _ = siblingApplications.launched(Self.siblingSnapshot(application))
        }
    }

    private func autoConversionHealthText() -> String {
        // Sibling presence follows lifecycle notifications; all other health
        // queries run only on explicit UI refresh paths, not in the key callback.
        if hasSiblingRuSwitcherInstance() {
            return L10n.statusSiblingInstance
        }
        guard SettingsManager.shared.autoSwitchEnabled, SettingsManager.shared.autoConvert else {
            return L10n.statusDisabled
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else { return L10n.statusPermissions }
        if AutoSwitchPolicy.secureInputActive { return L10n.statusSecureInput }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if AutoSwitchPolicy.isDeniedApp(bundleID) { return L10n.statusDeniedApp }
        guard languageModel != nil else { return L10n.statusModelUnavailable }
        guard let languages = LayoutSwitcher.currentAndOppositeLanguage() else {
            return L10n.statusUnsupportedPair
        }
        let pair = Set([
            String(languages.current.lowercased().prefix(2)),
            String(languages.opposite.lowercased().prefix(2)),
        ])
        guard pair == Set(["en", "ru"]) else { return L10n.statusUnsupportedPair }
        return L10n.statusActive
    }

    /// Подпись монохромной плашки — родная аббревиатура языка, как у системного индикатора.
    private func currentBadgeLabel() -> String {
        if let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty {
            let code = String(lang.prefix(2))
            let labels: [String: String] = [
                "ru": "РУ", "en": "EN", "uk": "УК", "be": "БЕ",
                "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
                "pt": "PT", "pl": "PL", "ja": "あ", "zh": "拼", "ko": "한",
                "he": "עב",   // иврит (3.0)
                "el": "ΕΛ", "bg": "БГ", "hy": "ՀԱ", "ka": "ქა",
            ]
            return labels[code] ?? code.uppercased()
        }
        // Язык раскладки недоступен — мягкий фолбэк по ID (как у flagForCurrentLayout).
        let id = LayoutSwitcher.currentLayoutID().lowercased()
        return (id.contains("russian") || id.hasSuffix(".ru")) ? "РУ" : "EN"
    }

    /// Монохромная плашка в стиле системного индикатора раскладки Sequoia: скруглённый
    /// прямоугольник с «выбитыми» буквами. Template-image — система сама красит её под
    /// светлый/тёмный меню-бар и пользовательский тинт.
    private func badgeImage(for label: String) -> NSImage {
        if let cached = badgeCache[label] { return cached }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let size = NSSize(width: max(ceil(textSize.width) + 8, 20), height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Буквы «выбиваются» из плашки (прозрачные), как у системного индикатора.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.isTemplate = true
        badgeCache[label] = image
        return image
    }

    /// Флаг текущей раскладки по коду языка (BCP-47), а не по подстроке в ID — иначе
    /// "Belarusian" ложно матчил "ru", а любая не-RU/EN пара показывалась как 🇺🇸.
    func flagForCurrentLayout() -> String {
        guard let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty else {
            // Язык раскладки недоступен — мягкий фолбэк по ID.
            let id = LayoutSwitcher.currentLayoutID().lowercased()
            return (id.contains("russian") || id.hasSuffix(".ru")) ? "🇷🇺" : "🇺🇸"
        }
        return Self.flagBadge(forLanguage: lang)
    }

    /// Единый бейдж раскладки для иконки меню-бара и списка раскладок в меню:
    /// «🇷🇺» для известных языков, иначе код («EL»).
    private static func flagBadge(forLanguage lang: String) -> String {
        let code = String(lang.lowercased().prefix(2))
        let flags: [String: String] = [
            "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾",
            "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
            "pt": "🇵🇹", "pl": "🇵🇱", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷",
            "he": "🇮🇱",   // иврит (3.0). Арабский в 3.1 — глифом ع (флага нет), см. дизайн 3.0.
        ]
        return flags[code] ?? code.uppercased()
    }

    /// issue #10: создаёт/освобождает индикатор каретки по флагу настроек. Создаётся лениво,
    /// только когда фича включена И мониторинг запущен (нужны разрешения).
    private func syncCaretIndicator() {
        keyboardMonitor.caretFlagEnabled = SettingsManager.shared.caretFlag   // гейт диспатча onUserInput
        if SettingsManager.shared.caretFlag, monitoringActive {
            if caretIndicator == nil {
                let ci = CaretIndicator()
                ci.flagProvider = { [weak self] in self?.flagForCurrentLayout() ?? "" }
                caretIndicator = ci
            }
        } else {
            caretIndicator?.teardown()
            caretIndicator = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        SettingsManager.shared.autoSwitchEnabled.toggle()
        let enabled = SettingsManager.shared.autoSwitchEnabled
        cancelDeferredManualLearning()
        invalidateConversionAttempts()
        textConverter.clearState()
        keyboardMonitor.markConverted()
        sender.title = enabled ? L10n.menuPause : L10n.menuResume
        settingsController.updateAutoSwitchState(enabled)
    }

    @objc private func toggleCurrentApplication(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var excluded = SettingsManager.shared.deniedApps
        if excluded.contains(bundleID) { excluded.removeAll { $0 == bundleID } }
        else { excluded.append(bundleID) }
        SettingsManager.shared.deniedApps = excluded
        cancelDeferredManualLearning()
        invalidateConversionAttempts()
        textConverter.clearState()
        keyboardMonitor.markConverted()
        settingsController.refresh()
    }

    @objc private func openDictionary() { settingsController.showWindow(section: .dictionary) }

    @objc private func undoLearningFromMenu() { learningUndoAction?() }

    /// Пересоздаёт event tap и, если создание не удалось (например, session-tap отклонён),
    /// ретраит — иначе тумблер «вкл», а tap'а нет, и приложение молча не реагирует на триггер.
    private func reconfigureTap(attempt: Int = 0) {
        if attempt == 0 { tapReconfigureWorkItem?.cancel() }
        if keyboardMonitor.reconfigure() {
            monitoringActive = true
            tapReconfigureWorkItem = nil
            return
        }

        monitoringActive = false
        let delays: [TimeInterval] = [1, 3, 10]
        guard attempt < delays.count else {
            rslog("event_tap_reconfigure_exhausted")
            return
        }
        rslog("event_tap_reconfigure_retry_scheduled")
        let work = DispatchWorkItem { [weak self] in
            self?.reconfigureTap(attempt: attempt + 1)
        }
        tapReconfigureWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt], execute: work)
    }

    @objc private func recheckPermissions() {
        runPermissionWizard(interactive: true)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func openGitHub() {
        if let url = URL(string: SettingsManager.githubURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        personalLexicon.flush()
        sessionResumeWorkItem?.cancel()
        tapReconfigureWorkItem?.cancel()
        permissionCheckTimer?.invalidate()
        iconRefreshTimer?.invalidate()
        updateCheckTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
    }

    @objc private func quit() {
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
