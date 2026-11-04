import Foundation
import AppKit
import XCTest
@testable import RuSwitcher

final class SelfAccessibilityTests: XCTestCase {
    @MainActor
    func testOwnSwiftUISettingsDoubleShiftCompletesWithoutClipboard() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUSWITCH_ALLOW_FOCUS_STEALING"] == "1")
        try XCTSkipUnless(CGPreflightListenEventAccess() && CGPreflightPostEventAccess(),
                          "Native keyboard test requires existing event permissions")
        try XCTSkipIf(NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            ($0.bundleIdentifier?.hasPrefix("com.cerfswitcher.") == true ||
             $0.bundleIdentifier?.hasPrefix("com.ruswitcher.") == true)
        }, "Stop the installed switcher before running a second event tap")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let settings = SettingsWindowController()
        settings.showWindow()
        defer { app.windows.forEach { $0.close() } }
        try await Task.sleep(for: .milliseconds(300))
        try XCTSkipUnless(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                          "Test settings window did not acquire focus")
        let converter = TextConverter(focusedElementResolver: NativeFocusedEditableResolver())
        let pasteboardCount = NSPasteboard.general.changeCount
        let preferences = SettingsManager.shared
        let previous = (preferences.triggerKey, preferences.triggerRightOnly, preferences.triggerDoubleTap)
        preferences.triggerKey = "shift"
        preferences.triggerRightOnly = false
        preferences.triggerDoubleTap = true
        defer {
            preferences.triggerKey = previous.0
            preferences.triggerRightOnly = previous.1
            preferences.triggerDoubleTap = previous.2
        }
        let completed = expectation(description: "Three double-Shift gestures complete")
        completed.expectedFulfillmentCount = 3
        completed.assertForOverFulfill = true
        let monitor = KeyboardMonitor(focusedElementResolver: NativeFocusedEditableResolver())
        try XCTSkipUnless(monitor.start {
            converter.convertSelectedText(allowClipboardFallback: false) { _ in completed.fulfill() }
        }, "Native event tap unavailable")
        defer { monitor.stop() }
        for _ in 0..<3 {
            try XCTSkipUnless(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                              "Focus changed during native test")
            for pressed in [true, false, true, false] {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: pressed))
                event.type = .flagsChanged
                event.flags = pressed ? .maskShift : []
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(60))
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(NSPasteboard.general.changeCount, pasteboardCount)
    }

    func testBackgroundLookupNeverEntersOwnAccessibilityTree() async {
        let blocked = await Task.detached {
            let resolver = NativeFocusedEditableResolver()
            let result = resolver.resolve(
                processID: ProcessInfo.processInfo.processIdentifier,
                timeoutMilliseconds: 250,
                allowTreeSearch: true
            )
            if case .unavailable(.noEditableElement) = result { return true }
            return false
        }.value
        XCTAssertTrue(blocked)
    }

    func testBackgroundLeaseNeverCallsOwnElementOperation() async {
        let blocked = await Task.detached {
            let resolver = NativeFocusedEditableResolver()
            let result = resolver.withElement(
                processID: ProcessInfo.processInfo.processIdentifier,
                timeoutMilliseconds: 250,
                allowTreeSearch: true
            ) { _ in "must not run" }
            if case .unavailable(.noEditableElement) = result { return true }
            return false
        }.value
        XCTAssertTrue(blocked)
    }
}
