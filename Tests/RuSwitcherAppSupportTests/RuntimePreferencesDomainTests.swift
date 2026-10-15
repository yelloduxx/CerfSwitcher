import XCTest
@testable import RuSwitcherAppSupport

final class RuntimePreferencesDomainTests: XCTestCase {
    func testHIDProbeUsesIsolatedPreferences() {
        XCTAssertEqual(
            RuntimePreferencesDomain.isolatedSuiteName(
                arguments: ["RuSwitcher", "--hid-probe-file", "fixture.json"]
            ),
            RuntimePreferencesDomain.hidProbeSuiteName
        )
    }

    func testManualPersistenceTestCanExplicitlyUseStandardPreferences() {
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: [
            "RuSwitcher",
            "--hid-probe",
            "manual-learning-double-shift",
            "--hid-use-standard-preferences",
        ]))
    }

    func testNormalApplicationUsesStandardPreferences() {
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: ["RuSwitcher"]))
    }

    func testExternalProbeUsesUniqueDomainAndCannotOptIntoUserPreferences() {
        let id = "1E89483A-DB80-44F4-A9AB-9ED5049F531E"
        XCTAssertEqual(RuntimePreferencesDomain.isolatedSuiteName(arguments: [
            "RuSwitcher", "--external-native-probe", id, "/tmp/session.json", "--hid-use-standard-preferences"
        ]), "com.ruswitcher.nativeprobe." + id.lowercased())
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: ["RuSwitcher", "--external-native-probe", "invalid"]))
    }

    func testSettingsSnapshotsNeverReadUserPreferences() {
        XCTAssertEqual(RuntimePreferencesDomain.isolatedSuiteName(arguments: [
            "RuSwitcher", "--render-settings-snapshots", "/tmp/out", "--hid-use-standard-preferences"
        ]), "com.ruswitcher.settingssnapshot")
    }
}
