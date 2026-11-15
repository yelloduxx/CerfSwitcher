import AppKit
import RuSwitcherAppSupport

// Migrate before the first settings read, and only for the installed product.
if Bundle.main.bundleIdentifier == ProductIdentity.bundleIdentifier {
    LegacyPreferencesMigration.run(
        legacyDomain: ProductIdentity.legacyBundleIdentifier,
        targetDomain: ProductIdentity.bundleIdentifier,
        into: .standard
    )
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
