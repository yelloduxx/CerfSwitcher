import AppKit

/// The active application, refreshed from workspace activation notifications.
/// Reading `NSWorkspace.frontmostApplication` per key made a synchronous
/// LaunchServices round trip inside the event tap (2-4 ms spikes).
/// Main-thread only: the tap and the notification both run on the main run loop.
final class FrontmostApplicationTracker: @unchecked Sendable {
    static let shared = FrontmostApplicationTracker()

    private(set) var processID: pid_t = 0
    private(set) var bundleID: String?
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.update(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    func refresh() {
        update(NSWorkspace.shared.frontmostApplication)
    }

    private func update(_ application: NSRunningApplication?) {
        processID = application?.processIdentifier ?? 0
        bundleID = application?.bundleIdentifier
    }
}
