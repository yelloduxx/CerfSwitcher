import AppKit
import RuSwitcherAppSupport

if CommandLine.arguments.contains(RuntimePreferencesDomain.settingsSnapshotArgument) {
    SettingsSnapshotRenderer.run(arguments: CommandLine.arguments)
} else if CommandLine.arguments.contains("--external-native-probe") {
    ExternalNativeProbe.run()
} else if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--ax-resolver-probe" {
    AXResolverProbe.run(processIDString: CommandLine.arguments[2])
} else if CommandLine.arguments.count >= 3,
   ["--hid-probe", "--hid-probe-file", "--hid-transport-probe-file"].contains(CommandLine.arguments[1]) {
    let resultPath: String?
    if let index = CommandLine.arguments.firstIndex(of: "--result"),
       CommandLine.arguments.indices.contains(index + 1) {
        resultPath = CommandLine.arguments[index + 1]
    } else {
        resultPath = nil
    }
    if CommandLine.arguments[1] == "--hid-probe-file" || CommandLine.arguments[1] == "--hid-transport-probe-file" {
        HIDIntegrationProbe.run(
            fixturePath: CommandLine.arguments[2],
            resultPath: resultPath,
            startProductionMonitoring: CommandLine.arguments[1] == "--hid-probe-file"
        )
    } else {
        HIDIntegrationProbe.run(scenarioName: CommandLine.arguments[2], resultPath: resultPath)
    }
} else {
    // Before AppDelegate or SettingsManager read anything from the standard
    // domain. Unbundled debug runs have another domain and must not copy.
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
}
