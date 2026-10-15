import AppKit
import RuSwitcherCore
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.section.title)
                        .font(.system(size: 22, weight: .bold))
                    page
                }
                .padding(.horizontal, 28)
                .padding(.top, 46)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .overview: OverviewPage(model: model)
        case .keyboard: KeyboardPage(model: model)
        case .exceptions: ExceptionsPage()
        case .dictionary: DictionaryPage(model: model)
        case .advanced: AdvancedPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIconView(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProductIdentity.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(AppVersion.short)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, isSelected: model.section == section) {
                    model.section = section
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 214)
        .frame(maxHeight: .infinity)
        .background(scheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.035))
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                IconBadge(symbol: section.symbol, tint: section.tint, size: 22)
                Text(section.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HeroCard(model: model)

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            FeatureTile(symbol: "wand.and.stars", tint: .purple,
                        title: L10n.settingsTileAutoConvert, hint: L10n.settingsTileAutoConvertHint,
                        isOn: model.binding(.autoConvert))
            FeatureTile(symbol: "flag.fill", tint: .red,
                        title: L10n.settingsTileCaretFlag, hint: L10n.settingsTileCaretFlagHint,
                        isOn: model.binding(.caretFlag))
            FeatureTile(symbol: "macwindow.on.rectangle", tint: .blue,
                        title: L10n.settingsTilePerApp, hint: L10n.settingsTilePerAppHint,
                        isOn: model.binding(.perAppLayout))
            FeatureTile(symbol: "power", tint: .green,
                        title: L10n.settingsLaunchAtLogin, hint: L10n.settingsTileLaunchHint,
                        isOn: model.binding(.launchAtLogin))
        }

        SettingsCard(title: L10n.settingsHowTo) {
            HowToRow(model: model)
        }

        SettingsCard(title: L10n.settingsCardGeneral) {
            SettingRow(symbol: "globe", tint: .blue, title: L10n.settingsLanguage.withoutColon) {
                OptionPicker(selection: model.languageBinding, options: model.languageOptions)
            }
        }
    }
}

private struct HeroCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let state = model.heroState
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                AppIconView(size: 54)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 5) {
                    Label(state.title, systemImage: state.symbol)
                        .font(.system(size: 18, weight: .bold))
                    Text(state.detail)
                        .font(.system(size: 12))
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(L10n.settingsAutoSwitch, isOn: model.binding(.enabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(L10n.settingsAutoSwitch)
                    .padding(4)
                    .background(Capsule().fill(.white.opacity(0.2)))
            }
            HStack(spacing: 8) {
                PermissionChip(title: L10n.settingsPermAccessibility, granted: model.permissions.accessibility)
                PermissionChip(title: L10n.settingsPermInputMonitoring, granted: model.permissions.inputMonitoring)
                Spacer(minLength: 0)
                if !model.permissions.allGranted {
                    Button(L10n.menuCheckPermissions) { model.onAction(.checkPermissions) }
                        .controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: state.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "keyboard")
                    .font(.system(size: 120, weight: .light))
                    .foregroundStyle(.white.opacity(0.10))
                    .offset(x: 24, y: 30)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }
}

private struct PermissionChip: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(title)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(granted ? 0.18 : 0.28)))
    }
}

private struct FeatureTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let hint: String
    @Binding var isOn: Bool

    /// The whole tile is one button; the switch only mirrors the state, so a
    /// click on it cannot toggle twice.
    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    IconBadge(symbol: symbol, tint: tint, size: 32)
                    Spacer()
                    Toggle(title, isOn: .constant(isOn))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .allowsHitTesting(false)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .cardBackground(highlight: isOn ? tint : nil, cornerRadius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

private struct HowToRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, glyph in
                    KeyCap(glyph: glyph)
                }
            }
            Text(L10n.settingsHotkey)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var keycaps: [String] {
        let caps = TriggerOptions.keycaps(for: model.triggerBinding.wrappedValue)
        return model.isOn(.triggerDoubleTap) ? caps + caps : caps
    }
}

private struct KeyCap: View {
    let glyph: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(glyph)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 34, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.white)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}

// MARK: - Keyboard

private struct KeyboardPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard(title: L10n.settingsCardTrigger, footer: L10n.settingsTriggerHint) {
            SettingRow(symbol: "command", tint: .indigo, title: L10n.settingsTrigger.withoutColon) {
                Picker("", selection: model.triggerBinding) {
                    ForEach(TriggerOptions.single) { Text($0.title).tag($0.id) }
                    Divider()
                    ForEach(TriggerOptions.combos) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 240)
            }
            RowDivider()
            ToggleRow(symbol: "arrow.right.to.line", tint: .teal,
                      title: L10n.settingsTriggerRightOnly, isOn: model.binding(.triggerRightOnly))
            RowDivider()
            ToggleRow(symbol: "hand.tap.fill", tint: .pink,
                      title: L10n.settingsTriggerDoubleTap, isOn: model.binding(.triggerDoubleTap))
        }

        SettingsCard(title: L10n.settingsHowTo) {
            HowToRow(model: model)
        }

        SettingsCard(title: L10n.settingsCardLayouts) {
            SettingRow(symbol: "1.circle.fill", tint: .blue, title: L10n.settingsLayout1.withoutColon) {
                OptionPicker(selection: model.layout1Binding, options: model.layoutOptions)
            }
            RowDivider()
            SettingRow(symbol: "2.circle.fill", tint: .red, title: L10n.settingsLayout2.withoutColon) {
                OptionPicker(selection: model.layout2Binding, options: model.layoutOptions)
            }
        }
    }
}

// MARK: - Exceptions

private struct ExceptionsPage: View {
    var body: some View {
        SettingsCard(title: L10n.settingsExceptionsApps, footer: L10n.settingsExceptionsAppsHint) {
            ExceptionListView(height: 168, makeEditor: {
                ExceptionListEditor(
                    kind: .apps,
                    get: { SettingsManager.shared.deniedApps },
                    set: { SettingsManager.shared.deniedApps = $0 },
                    isProtected: { AutoSwitchPolicy.protectedApps.contains($0) })
            })
        }
        SettingsCard(title: L10n.settingsExceptionsNever, footer: L10n.settingsExceptionsNeverHint) {
            ExceptionListView(height: 120, makeEditor: {
                ExceptionListEditor(
                    kind: .words,
                    get: { SettingsManager.shared.deniedWords },
                    set: { SettingsManager.shared.deniedWords = $0 },
                    addWordPrompt: L10n.settingsAddWordPrompt)
            })
        }
        SettingsCard(title: L10n.settingsExceptionsAlways, footer: L10n.settingsExceptionsAlwaysHint) {
            ExceptionListView(height: 120, makeEditor: {
                ExceptionListEditor(
                    kind: .words,
                    get: { SettingsManager.shared.alwaysConvertWords },
                    set: { SettingsManager.shared.alwaysConvertWords = $0 },
                    addWordPrompt: L10n.settingsAddWordPrompt)
            })
        }
    }
}

private struct ExceptionListView: View {
    let height: CGFloat
    let makeEditor: () -> ExceptionListEditor

    var body: some View {
        ExceptionListHost(makeEditor: makeEditor)
            .frame(height: height)
    }
}

/// Hosts the AppKit list editor. The coordinator owns the editor because the
/// table holds its data source and delegate weakly.
private struct ExceptionListHost: NSViewRepresentable {
    let makeEditor: () -> ExceptionListEditor

    func makeCoordinator() -> ExceptionListEditor { makeEditor() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeContainer(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Picker("", selection: $model.dictionaryTab) {
            ForEach(DictionaryTab.allCases) { tab in
                Text(verbatim: "\(tab.title) (\(model.dictionaryCounts[tab] ?? 0))").tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch model.dictionaryTab {
        case .mine: MyWordsTab(model: model)
        case .learned: LearnedPairsTab(model: model)
        case .remembered: RememberedWordsTab(model: model)
        }
    }
}

private extension DictionaryTab {
    var title: String {
        switch self {
        case .mine: L10n.settingsDictionaryTabMine
        case .learned: L10n.settingsDictionaryTabLearned
        case .remembered: L10n.settingsDictionaryTabRemembered
        }
    }
}

private struct MyWordsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var draft = ""
    @State private var selection = Set<String>()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsCard(title: L10n.settingsDictionaryAddTitle, footer: L10n.settingsDictionaryHint) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    if draft.isEmpty {
                        Text(L10n.settingsDictionaryPlaceholder)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(scheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                HStack(spacing: 8) {
                    Button(L10n.commonAdd) {
                        model.onChange(.addDictionaryWords(draft))
                        draft = ""
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.settingsDictionaryImport) { model.onAction(.importDictionary) }
                    Button(L10n.settingsDictionaryExport) { model.onAction(.exportDictionary) }
                        .disabled(model.wordRows.isEmpty)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let report = model.dictionaryReport {
                    Label(report, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }

        DictionaryListCard(
            title: String(format: L10n.settingsDictionaryCount, model.wordRows.count),
            empty: L10n.settingsDictionaryEmpty,
            rows: model.wordRows, height: 180, selection: $selection,
            remove: { model.onChange(.removeDictionaryWords($0)) }
        ) {
            Button { model.onAction(.clearDictionary) } label: {
                Text(L10n.settingsDictionaryClear).foregroundColor(.red)
            }
            .fixedSize()
        } row: { row in
            Text(row.word)
        }
    }
}

private struct LearnedPairsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var selection = Set<LearnedEntry>()

    var body: some View {
        DictionaryListCard(
            title: String(format: L10n.settingsLearnedCount, model.learnedRows.count),
            footer: L10n.settingsLearnedHint, empty: L10n.settingsLearnedEmpty,
            rows: model.learnedRows, height: 330, selection: $selection,
            remove: { model.onChange(.removeLearnedEntries($0)) }
        ) {
            EmptyView()
        } row: { row in
            HStack(spacing: 6) {
                Text(row.id.original)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(row.id.converted)
                if let app = row.appName {
                    Label(String(format: L10n.settingsLearnedNotIn, app), systemImage: "nosign")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct RememberedWordsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var selection = Set<PersonalWord>()

    var body: some View {
        DictionaryListCard(
            title: String(format: L10n.settingsRememberedCount, model.personalRows.count),
            footer: L10n.settingsRememberedHint, empty: L10n.settingsRememberedEmpty,
            rows: model.personalRows, height: 330, selection: $selection,
            remove: { model.onChange(.removePersonalWords($0)) }
        ) {
            Button(L10n.settingsRememberedMove) {
                model.onChange(.movePersonalWordsToDictionary(selection))
                selection = []
            }
            .disabled(selection.isEmpty)
            .fixedSize()
        } row: { row in
            Text(row.id.word)
        }
    }
}

/// A searchable, multi-select list card shared by the Dictionary tabs. The
/// table-backed `List` draws only visible rows, so 20,000 entries stay smooth.
private struct DictionaryListCard<Row: DictionaryListRow, Actions: View, RowContent: View>: View {
    let title: String
    var footer: String?
    let empty: String
    let rows: [Row]
    let height: CGFloat
    @Binding var selection: Set<Row.ID>
    let remove: (Set<Row.ID>) -> Void
    @ViewBuilder let actions: Actions
    @ViewBuilder let row: (Row) -> RowContent
    @State private var query = ""

    var body: some View {
        SettingsCard(title: title, footer: footer) {
            if rows.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                HStack(spacing: 8) {
                    TextField(L10n.settingsDictionarySearch, text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.settingsDictionaryRemove, action: removeSelection)
                        .disabled(selection.isEmpty)
                        .fixedSize()
                    actions
                }
                .padding(10)
                Divider()
                List(DictionarySearch.filter(rows, query: query), selection: $selection) { item in
                    HStack(spacing: 6) {
                        row(item)
                        Spacer(minLength: 8)
                        if item.overridden {
                            Text(L10n.settingsDictionaryOverridden)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                                .help(L10n.settingsDictionaryOverriddenHelp)
                        }
                    }
                    .font(.system(size: 12))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand(perform: removeSelection)
                .frame(height: height)
            }
        }
    }

    private func removeSelection() {
        guard !selection.isEmpty else { return }
        remove(selection)
        selection = []
    }
}

// MARK: - Advanced

private struct AdvancedPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard(title: L10n.settingsCardSpecial) {
            ToggleRow(symbol: "terminal.fill", tint: .orange,
                      title: L10n.settingsAxlessConversion, hint: L10n.settingsAxlessConversionHint,
                      isOn: model.binding(.axlessConversion))
            if model.showsRemoteDesktop {
                RowDivider()
                ToggleRow(symbol: "display.2", tint: .cyan,
                          title: L10n.menuRemoteDesktop, hint: L10n.settingsRemoteDesktopHint,
                          isOn: model.binding(.remoteDesktop))
            }
        }

        SettingsCard(title: L10n.settingsCardLearning) {
            SettingRow(symbol: "brain", tint: .pink, title: engineDescription) { EmptyView() }
            RowDivider()
            HStack(spacing: 8) {
                Button(L10n.settingsExportLearning) { model.onAction(.exportLearning) }
                    .fixedSize()
                Button(L10n.settingsImportLearning) { model.onAction(.importLearning) }
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            RowDivider()
            SettingRow(symbol: "arrow.counterclockwise", tint: .red, title: L10n.settingsClearLearning) {
                Button { model.onAction(.clearLearning) } label: {
                    Text(L10n.settingsClearLearningButton).foregroundColor(.red)
                }
                .fixedSize()
            }
        }

        SettingsCard(title: L10n.settingsCardDiagnostics) {
            ToggleRow(symbol: "ladybug.fill", tint: .green,
                      title: L10n.settingsDebugLog, hint: L10n.settingsDebugLogHint,
                      isOn: model.binding(.debugLog))
            RowDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(L10n.settingsShowLog) { model.onAction(.showLog) }
                    Button(L10n.settingsSendLog) { model.onAction(.sendLog) }
                    Spacer(minLength: 0)
                }
                Text(ProductIdentity.logFilePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var engineDescription: String {
        let engineVersion = LanguageModelStore.bundled != nil ? "V3" : "unavailable"
        let modelVersion = LanguageModelStore.bundled?.metadata.modelVersion ?? "unavailable"
        return String(format: L10n.settingsSmartEngine, engineVersion, modelVersion)
    }
}

// MARK: - About

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 8) {
            AppIconView(size: 88)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            Text(ProductIdentity.displayName)
                .font(.system(size: 24, weight: .bold))
            Text(AppVersion.full)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(L10n.settingsVersion)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(L10n.settingsStarOnGithub) { model.onAction(.openGitHub) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .cardBackground(highlight: nil, cornerRadius: 12)

        SettingsCard(title: L10n.settingsCardUpdates) {
            ToggleRow(symbol: "arrow.triangle.2.circlepath", tint: .green,
                      title: L10n.settingsCheckUpdates, hint: L10n.settingsCheckUpdatesHint,
                      isOn: model.binding(.checkUpdates))
            RowDivider()
            HStack {
                Button(L10n.menuCheckUpdates) { model.onAction(.checkUpdates) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Building blocks

private struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) { content }
                .cardBackground(highlight: nil, cornerRadius: 12)
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct SettingRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var hint: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var hint: String?
    let isOn: Binding<Bool>

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, hint: hint) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

private struct OptionPicker: View {
    let selection: Binding<String>
    let options: [PickerOption]

    var body: some View {
        Picker("", selection: selection) {
            ForEach(options) { Text($0.title).tag($0.id) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 240)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 52)
    }
}

private struct IconBadge: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private struct CardBackground: ViewModifier {
    let highlight: Color?
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(highlight.map { $0.opacity(0.5) } ?? Color.primary.opacity(0.09)))
            .clipShape(shape)
    }

    private var fill: Color {
        if let highlight { return highlight.opacity(scheme == .dark ? 0.16 : 0.09) }
        return scheme == .dark ? Color.white.opacity(0.055) : Color.white
    }
}

private extension View {
    func cardBackground(highlight: Color?, cornerRadius: CGFloat) -> some View {
        modifier(CardBackground(highlight: highlight, cornerRadius: cornerRadius))
    }
}

private extension String {
    /// Older labels end with a colon for the form layout; rows show the bare noun.
    var withoutColon: String {
        trimmingCharacters(in: CharacterSet(charactersIn: ":：").union(.whitespaces))
    }
}

enum AppVersion {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private static var version: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    private static var build: String { info["CFBundleVersion"] as? String ?? "?" }
    private static var devTag: String { info["RSDevTag"] as? String ?? "" }

    static var short: String { "v\(version)" }
    static var full: String { "v\(version)\(devTag) (\(build))" }
}
