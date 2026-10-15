import AppKit
import RuSwitcherAppSupport
import RuSwitcherCore
import SwiftUI

/// Renders every settings page offscreen to PNG, in light and dark appearance.
/// The window is never ordered front and the process never activates, so the
/// desktop focus is untouched. Preferences come from an isolated, wiped suite.
///
/// Usage: RuSwitcher --render-settings-snapshots <dir> <prefix>
///        [-com.ruswitcher.interfaceLanguage ru]
@MainActor
enum SettingsSnapshotRenderer {
    static func run(arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: RuntimePreferencesDomain.settingsSnapshotArgument),
              arguments.indices.contains(index + 2) else {
            FileHandle.standardError.write(Data("usage: --render-settings-snapshots <dir> <prefix>\n".utf8))
            exit(64)
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let prefix = arguments[index + 2]

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        if let icon = NSImage(contentsOfFile: "RuSwitcher.icns") {
            app.applicationIconImage = icon
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let appearances: [(name: String, appearance: NSAppearance.Name)] = [
                ("light", .aqua), ("dark", .darkAqua),
            ]
            for (appearanceName, appearanceID) in appearances {
                let controller = SettingsWindowController()
                for page in controller.snapshotPages() {
                    let url = directory.appendingPathComponent("\(prefix)-\(page.name)-\(appearanceName).png")
                    try render(page.view, appearance: NSAppearance(named: appearanceID), to: url)
                    print(url.path)
                }
            }
            try measureFullDictionary(directory: directory, prefix: prefix)
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// Fills the isolated stores to their limits with made-up words and times
    /// what the Dictionary page does with them: reading a store into rows,
    /// one search pass and the first layout of the list. Prints the numbers
    /// and renders the full My Words tab.
    private static func measureFullDictionary(directory: URL, prefix: String) throws {
        let settings = SettingsManager.shared
        // A stride by a number coprime to the count shuffles the order, so
        // sorting does real work.
        let count = UserDictionary.maximumWordCount
        let words = (0..<count).map { syntheticWord($0 * 7_919 % count) }
        settings.userDictionary.add(text: words.joined(separator: "\n"))
        let ruleLimit = 2_000
        settings.adaptiveRuleBook = AdaptiveRuleBook(rules: words.prefix(ruleLimit).map {
            AdaptiveRule(original: $0, converted: KeyMapping.convert($0), positiveCount: 1, confirmed: true)
        })
        let start = Date()
        for word in words.prefix(PersonalLexicon.promotedLimit - 1) {
            for occasion in 0..<PersonalLexicon.promotionCount {
                settings.personalLexicon.observe(word: KeyMapping.convert(word), language: "ru",
                                                 at: start.addingTimeInterval(Double(occasion) * 3_600))
            }
        }
        defer {
            settings.userDictionary.clear()
            settings.adaptiveRuleBook = AdaptiveRuleBook()
            settings.personalLexicon.clear()
        }

        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> String {
            String(format: "%.1f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3)
        }
        for tab in DictionaryTab.allCases {
            let model = SettingsModel()
            model.dictionaryTab = tab
            let load = clock.measure { model.section = .dictionary }
            let count = model.wordRows.count + model.learnedRows.count + model.personalRows.count
            var filtered = 0
            let queries = ["a", "ab", "zzzz", "щ"]
            let filter = clock.measure {
                for query in queries {
                    filtered += DictionarySearch.filter(model.wordRows, query: query).count
                        + DictionarySearch.filter(model.learnedRows, query: query).count
                        + DictionarySearch.filter(model.personalRows, query: query).count
                }
            } / queries.count
            let view = NSHostingView(rootView: SettingsRootView(model: model))
            let window = SettingsWindowController.makeWindow(content: view)
            let firstLayout = clock.measure {
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            window.contentView = nil
            print("timing \(tab.rawValue): rows=\(count) load=\(milliseconds(load))ms "
                + "filter=\(milliseconds(filter))ms firstLayout=\(milliseconds(firstLayout))ms")
            if tab == .mine {
                let url = directory.appendingPathComponent("\(prefix)-dictionary-full-light.png")
                try render(NSHostingView(rootView: SettingsRootView(model: model)), appearance: NSAppearance(named: .aqua), to: url)
                print(url.path)
            }
        }
    }

    /// Distinct Latin letter strings of four or more letters: `aaab`, `aaac`…
    private static func syntheticWord(_ index: Int) -> String {
        var value = index
        var letters: [Character] = []
        for _ in 0..<4 {
            letters.append(Character(UnicodeScalar(UInt8(97 + value % 26))))
            value /= 26
        }
        return String(letters.reversed())
    }

    private static func render(_ view: NSView, appearance: NSAppearance?, to url: URL) throws {
        let window = SettingsWindowController.makeWindow(content: view)
        window.appearance = appearance
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let target = view.superview ?? view
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
