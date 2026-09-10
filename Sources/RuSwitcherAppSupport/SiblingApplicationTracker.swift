/// Cached sibling presence, updated by application lifecycle events rather
/// than by querying every running application's properties on each keystroke.
public struct SiblingApplicationTracker {
    public struct Application {
        public let processID: Int32
        public let bundleID: String?
        public let name: String?

        public init(processID: Int32, bundleID: String?, name: String?) {
            self.processID = processID
            self.bundleID = bundleID
            self.name = name
        }
    }

    private let ownProcessID: Int32
    private let ownBundleID: String
    private var siblings: Set<Int32> = []

    public init(ownProcessID: Int32, ownBundleID: String) {
        self.ownProcessID = ownProcessID
        self.ownBundleID = ownBundleID
    }

    public var hasSibling: Bool { !siblings.isEmpty }

    @discardableResult
    public mutating func replace(with applications: [Application]) -> Bool {
        let before = hasSibling
        siblings = Set(applications.filter(isSibling).map(\.processID))
        return before != hasSibling
    }

    @discardableResult
    public mutating func launched(_ application: Application) -> Bool {
        let before = hasSibling
        if isSibling(application) { siblings.insert(application.processID) }
        else { siblings.remove(application.processID) }
        return before != hasSibling
    }

    @discardableResult
    public mutating func terminated(processID: Int32) -> Bool {
        let before = hasSibling
        siblings.remove(processID)
        return before != hasSibling
    }

    private func isSibling(_ application: Application) -> Bool {
        guard application.processID != ownProcessID else { return false }
        return application.bundleID == "com.ruswitcher.app"
            || application.bundleID == "com.ruswitcher.lab"
            || application.bundleID == ownBundleID
            || application.name?.contains("RuSwitcher") == true
    }
}
