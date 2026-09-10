import Foundation

public struct PhysicalTypingStimulus: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let layoutIDs: [String]
    public let initialLayoutID: String
    public let keyboardType: UInt32
    public let actions: [PhysicalTypingAction]

    public init(
        id: String,
        layoutIDs: [String],
        initialLayoutID: String,
        keyboardType: UInt32 = 40,
        actions: [PhysicalTypingAction],
        version: Int = 1
    ) {
        self.version = version
        self.id = id
        self.layoutIDs = layoutIDs
        self.initialLayoutID = initialLayoutID
        self.keyboardType = keyboardType
        self.actions = actions
    }
}

public struct PhysicalTypingAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case keyDown, keyUp, selectLayout
    }

    public let kind: Kind
    public let atMicroseconds: UInt64
    public let keyCode: UInt16?
    public let shift: Bool
    public let capsLock: Bool
    public let autorepeat: Bool
    public let layoutID: String?

    public init(
        kind: Kind,
        atMicroseconds: UInt64,
        keyCode: UInt16? = nil,
        shift: Bool = false,
        capsLock: Bool = false,
        autorepeat: Bool = false,
        layoutID: String? = nil
    ) {
        self.kind = kind
        self.atMicroseconds = atMicroseconds
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
        self.autorepeat = autorepeat
        self.layoutID = layoutID
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

    public init(text: String, finalLayoutID: String, transactions: Int, checkpoints: [PhysicalTypingCheckpoint] = []) {
        self.text = text
        self.finalLayoutID = finalLayoutID
        self.transactions = transactions
        self.checkpoints = checkpoints
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
