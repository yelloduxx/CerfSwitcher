public struct ManualConversionLifecycle: Sendable {
    public private(set) var active: ConversionFeedback.Attempt?

    public init() {}

    public mutating func begin(_ attempt: ConversionFeedback.Attempt) -> Bool {
        guard active == nil else { return false }
        active = attempt
        return true
    }

    public func isCurrent(_ attempt: ConversionFeedback.Attempt) -> Bool {
        active == attempt
    }

    @discardableResult
    public mutating func finish(_ attempt: ConversionFeedback.Attempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        active = nil
        return true
    }
}
