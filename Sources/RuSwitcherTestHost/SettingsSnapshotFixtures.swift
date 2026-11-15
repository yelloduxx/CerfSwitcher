import AppKit
import RuSwitcherCore
import SwiftUI

@MainActor
extension SettingsWindowController {
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

}
