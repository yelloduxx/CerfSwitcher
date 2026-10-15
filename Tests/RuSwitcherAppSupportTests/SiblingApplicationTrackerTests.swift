import XCTest
@testable import RuSwitcherAppSupport

final class SiblingApplicationTrackerTests: XCTestCase {
    func testOwnInstanceAndUnrelatedApplicationsDoNotTriggerWarning() {
        var tracker = makeTracker()
        XCTAssertFalse(tracker.replace(with: [app(10, "com.cerfswitcher.app", "Cerf Switcher"),
                                               app(20, "test.editor", "Editor"),
                                               app(30, "test.other", "Cerf Switcher")]))
        XCTAssertFalse(tracker.hasSibling)
    }

    func testKnownAndNamedForksKeepExistingClassification() {
        for application in [app(20, "com.ruswitcher.app", "Author"),
                            app(20, "com.ruswitcher.lab", nil),
                            app(20, "com.ruswitcher.pro", nil),
                            app(20, "com.cerfswitcher.app", nil),
                            app(20, "custom.fork", "RuSwitcher Custom") ] {
            var tracker = makeTracker()
            XCTAssertTrue(tracker.launched(application))
            XCTAssertTrue(tracker.hasSibling)
        }
    }

    func testWarningClearsOnlyWhenLastSiblingTerminates() {
        var tracker = makeTracker()
        XCTAssertTrue(tracker.launched(app(20, "com.ruswitcher.app", nil)))
        XCTAssertFalse(tracker.launched(app(30, "com.ruswitcher.lab", nil)))
        XCTAssertFalse(tracker.launched(app(30, "com.ruswitcher.lab", nil)))
        XCTAssertFalse(tracker.terminated(processID: 20))
        XCTAssertTrue(tracker.hasSibling)
        XCTAssertTrue(tracker.terminated(processID: 30))
        XCTAssertFalse(tracker.hasSibling)
        XCTAssertFalse(tracker.terminated(processID: 30))
    }

    func testReusedPIDAndFreshSnapshotRemoveStaleWarning() {
        var tracker = makeTracker()
        tracker.launched(app(20, "com.ruswitcher.app", nil))
        XCTAssertTrue(tracker.launched(app(20, "test.editor", "Editor")))
        XCTAssertFalse(tracker.hasSibling)
        tracker.launched(app(30, "com.ruswitcher.lab", nil))
        XCTAssertTrue(tracker.replace(with: []))
        XCTAssertFalse(tracker.hasSibling)
    }

    private func makeTracker() -> SiblingApplicationTracker {
        .init(ownProcessID: 10, ownBundleID: "com.cerfswitcher.app")
    }

    private func app(_ pid: Int32, _ bundleID: String?, _ name: String?) -> SiblingApplicationTracker.Application {
        .init(processID: pid, bundleID: bundleID, name: name)
    }
}
