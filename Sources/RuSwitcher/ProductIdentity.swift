import Foundation

/// Production product identity for Cerf Switcher on `main`.
/// Bundle ID, logs, defaults domain and Accessibility grants are tied to this
/// identity — changing it requires re-granting permissions on install.
enum ProductIdentity {
    static let displayName = "Cerf Switcher"
    static let shortName = "CerfSwitcher"
    static let bundleIdentifier = "com.cerfswitcher.app"
    /// The previous product's defaults domain, copied once on first launch.
    static let legacyBundleIdentifier = "com.ruswitcher.pro"
    static let inputMethodBundleIdentifier = "com.cerfswitcher.inputmethod"
    static let inputMethodSourcePrefix = "com.cerfswitcher.inputmethod."
    static let logDirectoryName = "CerfSwitcher"
    static let logFileName = "cerf-switcher.log"
    /// Stable across builds so synthetic events never feed back into the tap.
    static let eventMarker: Int64 = 0x5255_5300 // 'RUS\0'
    /// Fresh installs start with double-Shift.
    static let defaultTriggerKey = "shift"
    static let defaultTriggerDoubleTap = true

    static var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/\(logDirectoryName)/\(logFileName)"
    }
}
