import Foundation

/// Explicit test-only launch configuration. A unique suite keeps rules and
/// preferences away from the user's normal application domain.
public struct ExternalNativeProbeConfiguration: Codable, Equatable, Sendable {
    public static let maximumActions = 10_000
    public let runID: UUID
    public let layoutIDs: [String]
    public let automaticConversion: Bool
    public let inputMarker: Int64
    public let replacementMarker: Int64
    public let timeoutSeconds: Double

    public init(runID: UUID, layoutIDs: [String], automaticConversion: Bool,
                inputMarker: Int64, replacementMarker: Int64, timeoutSeconds: Double = 45) {
        self.runID = runID
        self.layoutIDs = layoutIDs
        self.automaticConversion = automaticConversion
        self.inputMarker = inputMarker
        self.replacementMarker = replacementMarker
        self.timeoutSeconds = timeoutSeconds
    }

    public var preferencesDomain: String { "com.ruswitcher.nativeprobe.\(runID.uuidString.lowercased())" }

    public func inputEventMarker(actionIndex: Int) -> Int64? {
        guard (0..<Self.maximumActions).contains(actionIndex) else { return nil }
        let (marker, overflow) = inputMarker.addingReportingOverflow(Int64(actionIndex + 1))
        return overflow || marker == replacementMarker ? nil : marker
    }

    public func inputActionIndex(eventMarker: Int64) -> Int? {
        let (offset, overflow) = eventMarker.subtractingReportingOverflow(inputMarker)
        guard !overflow, (1...Int64(Self.maximumActions)).contains(offset), eventMarker != replacementMarker else { return nil }
        return Int(offset - 1)
    }

    public func validate() throws {
        guard layoutIDs.count == 2, Set(layoutIDs).count == 2, layoutIDs.allSatisfy({ !$0.isEmpty }),
              inputMarker > 0, inputMarker <= Int64.max - Int64(Self.maximumActions), replacementMarker != 0,
              !(inputMarker...(inputMarker + Int64(Self.maximumActions))).contains(replacementMarker),
              timeoutSeconds.isFinite, (1...120).contains(timeoutSeconds) else {
            throw ConfigurationError.invalid
        }
    }

    public static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 16_384 else { throw ConfigurationError.invalid }
        let config = try JSONDecoder().decode(Self.self, from: data)
        try config.validate()
        return config
    }

    public enum ConfigurationError: Error { case invalid }
}
