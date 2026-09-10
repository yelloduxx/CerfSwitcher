import Foundation

public struct PhysicalTypingStimulus: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let layoutIDs: [String]
    public let initialLayoutID: String
    public let keyboardType: UInt32
    public let actions: [PhysicalTypingAction]
    public let timing: PhysicalTypingTiming?

    public init(
        id: String,
        layoutIDs: [String],
        initialLayoutID: String,
        keyboardType: UInt32 = 40,
        actions: [PhysicalTypingAction],
        version: Int = 1,
        timing: PhysicalTypingTiming? = nil
    ) {
        self.version = version
        self.id = id
        self.layoutIDs = layoutIDs
        self.initialLayoutID = initialLayoutID
        self.keyboardType = keyboardType
        self.actions = actions
        self.timing = timing
    }
}

public struct PhysicalTypingAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case keyDown, keyUp, selectLayout, focusChange, tapRecovery
    }

    public let kind: Kind
    public let atMicroseconds: UInt64
    public let keyCode: UInt16?
    public let shift: Bool
    public let capsLock: Bool
    public let autorepeat: Bool
    public let layoutID: String?
    public let command: Bool
    public let control: Bool
    public let option: Bool
    public let fieldID: String?

    public init(
        kind: Kind,
        atMicroseconds: UInt64,
        keyCode: UInt16? = nil,
        shift: Bool = false,
        capsLock: Bool = false,
        autorepeat: Bool = false,
        layoutID: String? = nil,
        command: Bool = false,
        control: Bool = false,
        option: Bool = false,
        fieldID: String? = nil
    ) {
        self.kind = kind
        self.atMicroseconds = atMicroseconds
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
        self.autorepeat = autorepeat
        self.layoutID = layoutID
        self.command = command
        self.control = control
        self.option = option
        self.fieldID = fieldID
    }

    private enum CodingKeys: String, CodingKey {
        case kind, atMicroseconds, keyCode, shift, capsLock, autorepeat, layoutID, command, control, option, fieldID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind),
                  atMicroseconds: try values.decode(UInt64.self, forKey: .atMicroseconds),
                  keyCode: try values.decodeIfPresent(UInt16.self, forKey: .keyCode),
                  shift: try values.decodeIfPresent(Bool.self, forKey: .shift) ?? false,
                  capsLock: try values.decodeIfPresent(Bool.self, forKey: .capsLock) ?? false,
                  autorepeat: try values.decodeIfPresent(Bool.self, forKey: .autorepeat) ?? false,
                  layoutID: try values.decodeIfPresent(String.self, forKey: .layoutID),
                  command: try values.decodeIfPresent(Bool.self, forKey: .command) ?? false,
                  control: try values.decodeIfPresent(Bool.self, forKey: .control) ?? false,
                  option: try values.decodeIfPresent(Bool.self, forKey: .option) ?? false,
                  fieldID: try values.decodeIfPresent(String.self, forKey: .fieldID))
    }
}

/// An explicit test environment, not a measurement of macOS scheduling.
public struct PhysicalTypingTiming: Codable, Equatable, Sendable {
    public var deliveryDelayMicroseconds: UInt64 = 0
    public var syntheticEventIntervalMicroseconds: UInt64 = 0
    public var layoutDelayMicroseconds: UInt64 = 0
    public var verificationReadDelayMicroseconds: UInt64 = 1_000
    public var acknowledgementDelayMicroseconds: UInt64 = 0
    /// Callback work before the shared coordinator is invoked; input arrival
    /// and the editor clock continue independently while this lane is occupied.
    public var conversionPrePostMicroseconds: UInt64 = 0
    /// Synchronous post/layout work before switching and staging can finish.
    /// This is not synthetic event delivery latency or a per-word input pause.
    public var conversionPostWorkMicroseconds: UInt64 = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case deliveryDelayMicroseconds, syntheticEventIntervalMicroseconds, layoutDelayMicroseconds
        case verificationReadDelayMicroseconds, acknowledgementDelayMicroseconds
        case conversionPrePostMicroseconds, conversionPostWorkMicroseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        deliveryDelayMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .deliveryDelayMicroseconds) ?? 0
        syntheticEventIntervalMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .syntheticEventIntervalMicroseconds) ?? 0
        layoutDelayMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .layoutDelayMicroseconds) ?? 0
        verificationReadDelayMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .verificationReadDelayMicroseconds) ?? 1_000
        acknowledgementDelayMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .acknowledgementDelayMicroseconds) ?? 0
        conversionPrePostMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .conversionPrePostMicroseconds) ?? 0
        conversionPostWorkMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .conversionPostWorkMicroseconds) ?? 0
    }
}

public struct PhysicalTypingCheckpoint: Codable, Equatable, Sendable {
    public let actionIndex: Int
    public let layoutIDBefore: String

    public init(actionIndex: Int, layoutIDBefore: String) {
        self.actionIndex = actionIndex
        self.layoutIDBefore = layoutIDBefore
    }
}

/// Passed only to the assessor, never to the event interpreter.
public struct PhysicalTypingOracle: Codable, Equatable, Sendable {
    public let text: String
    public let finalLayoutID: String
    public let transactions: Int
    public let checkpoints: [PhysicalTypingCheckpoint]
    public let selectedRange: NSRange?
    public let verifiedCompletions: Int?

    public init(text: String, finalLayoutID: String, transactions: Int, checkpoints: [PhysicalTypingCheckpoint] = [],
                selectedRange: NSRange? = nil, verifiedCompletions: Int? = nil) {
        self.text = text
        self.finalLayoutID = finalLayoutID
        self.transactions = transactions
        self.checkpoints = checkpoints
        self.selectedRange = selectedRange
        self.verifiedCompletions = verifiedCompletions
    }
}

public struct PhysicalTypingFixture: Codable, Equatable, Sendable {
    public let stimulus: PhysicalTypingStimulus
    public let oracle: PhysicalTypingOracle

    public init(stimulus: PhysicalTypingStimulus, oracle: PhysicalTypingOracle) {
        self.stimulus = stimulus
        self.oracle = oracle
    }
}

public enum PhysicalTypingError: Error, Equatable {
    case invalidScenario(String)
    case unavailableLayout(String)
    case unsupportedAction(Int, String)
    case unrepresentableText(String, String)
}
