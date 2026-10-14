import AppKit
import RuSwitcherAppSupport

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
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    private static func render(_ view: NSView, appearance: NSAppearance?, to url: URL) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settingsTitle
        window.appearance = appearance
        window.contentView = view
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
