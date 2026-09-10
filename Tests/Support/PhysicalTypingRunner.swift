import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

public struct PhysicalTypingFaults: Equatable, Sendable {
    public var disableAutomaticConversion = false
    public var disableLayoutSwitch = false
    public var dropInsertion = false
    public var duplicateInsertion = false

    public init() {}
}

public struct PhysicalTypingObservation: Codable, Equatable, Sendable {
    public let actionIndex: Int
    public let atMicroseconds: UInt64
    public let layoutIDBefore: String
    public let layoutIDAfter: String
    public let producedText: String
    public let textAfter: String
}

public struct PhysicalTypingDecision: Codable, Equatable, Sendable {
    public let actionIndex: Int
    public let original: String
    public let replacement: String
    public let verdict: String
    public let reason: String
}

public struct PhysicalTypingExecution: Codable, Equatable, Sendable {
    public let text: String
    public let finalLayoutID: String
    public let transactions: Int
    public let observations: [PhysicalTypingObservation]
    public let decisions: [PhysicalTypingDecision]
}

public struct PhysicalTypingAssessment: Codable, Equatable, Sendable {
    public let passed: Bool
    public let failures: [String]

    public static func assess(_ execution: PhysicalTypingExecution, oracle: PhysicalTypingOracle) -> Self {
        var failures: [String] = []
        if execution.text != oracle.text { failures.append("text-mismatch") }
        if execution.finalLayoutID != oracle.finalLayoutID { failures.append("final-layout-mismatch") }
        if execution.transactions != oracle.transactions { failures.append("transaction-count-mismatch") }
        for checkpoint in oracle.checkpoints {
            guard execution.observations.indices.contains(checkpoint.actionIndex) else {
                failures.append("missing-checkpoint-\(checkpoint.actionIndex)")
                continue
            }
            if execution.observations[checkpoint.actionIndex].layoutIDBefore != checkpoint.layoutIDBefore {
                failures.append("checkpoint-layout-mismatch-\(checkpoint.actionIndex)")
            }
        }
        return Self(passed: failures.isEmpty, failures: failures)
    }
}

/// Closed-loop physical translation and V3 planning. Event delivery is still
/// ideal/synchronous: recorded timestamps are not an asynchronous editor model.
/// The runner deliberately has no access to a fixture's expected output.
public struct PhysicalTypingRunner {
    private let layouts: SystemTypingLayouts
    private let model: LanguageModelStore

    public init(layouts: SystemTypingLayouts, model: LanguageModelStore) {
        self.layouts = layouts
        self.model = model
    }

    public func run(_ stimulus: PhysicalTypingStimulus, faults: PhysicalTypingFaults = .init()) throws -> PhysicalTypingExecution {
        try validate(stimulus)
        var session = PhysicalTypingSession(stimulus: stimulus, layouts: layouts, model: model, faults: faults)
        for (index, action) in stimulus.actions.enumerated() {
            try session.apply(action, at: index)
        }
        return session.execution
    }

    private func validate(_ stimulus: PhysicalTypingStimulus) throws {
        guard stimulus.version == 1, !stimulus.id.isEmpty,
              stimulus.layoutIDs.count == 2,
              Set(stimulus.layoutIDs).count == 2,
              stimulus.layoutIDs.contains(stimulus.initialLayoutID),
              !stimulus.actions.isEmpty else {
            throw PhysicalTypingError.invalidScenario("invalid version, layout pair or empty stimulus")
        }
        let languages = try stimulus.layoutIDs.map { try layouts.layout($0).language }
        guard Set(languages) == Set(["en", "ru"]) else {
            throw PhysicalTypingError.invalidScenario("physical runner requires one EN and one RU layout")
        }
        var lastTime: UInt64 = 0
        var pressed: Set<UInt16> = []
        for (index, action) in stimulus.actions.enumerated() {
            guard action.atMicroseconds >= lastTime else {
                throw PhysicalTypingError.invalidScenario("event times must be monotonic")
            }
            lastTime = action.atMicroseconds
            switch action.kind {
            case .selectLayout:
                guard let id = action.layoutID, stimulus.layoutIDs.contains(id),
                      action.keyCode == nil, !action.autorepeat, !action.shift, !action.capsLock else {
                    throw PhysicalTypingError.invalidScenario("invalid layout action at \(index)")
                }
            case .keyDown, .keyUp:
                guard let code = action.keyCode, action.layoutID == nil else {
                    throw PhysicalTypingError.invalidScenario("missing keycode at \(index)")
                }
                guard KeyMapping.keycodeToEN[code] != nil || [36, 48, 49, 51].contains(code) else {
                    throw PhysicalTypingError.unsupportedAction(index, "keycode \(code)")
                }
                if action.kind == .keyDown {
                    guard action.autorepeat == pressed.contains(code) else {
                        throw PhysicalTypingError.invalidScenario("unbalanced keyDown at \(index)")
                    }
                    pressed.insert(code)
                } else {
                    guard !action.autorepeat, pressed.remove(code) != nil else {
                        throw PhysicalTypingError.invalidScenario("unbalanced keyUp at \(index)")
                    }
                }
            }
        }
        guard pressed.isEmpty else { throw PhysicalTypingError.invalidScenario("unreleased keys") }
    }
}

private struct PhysicalTypingSession {
    let stimulus: PhysicalTypingStimulus
    let layouts: SystemTypingLayouts
    let model: LanguageModelStore
    let faults: PhysicalTypingFaults
    private var activeLayoutID: String
    private var translation = KeyboardLayoutTranslationState()
    private var input = InputSession()
    private var text = ""
    private var transactions = 0
    private var observations: [PhysicalTypingObservation] = []
    private var decisions: [PhysicalTypingDecision] = []
    private let focus = FocusedElementIdentity(processID: 1, bundleID: "com.ruswitcher.physical-test", identifier: "editor")

    init(stimulus: PhysicalTypingStimulus, layouts: SystemTypingLayouts, model: LanguageModelStore, faults: PhysicalTypingFaults) {
        self.stimulus = stimulus
        self.layouts = layouts
        self.model = model
        self.faults = faults
        self.activeLayoutID = stimulus.initialLayoutID
    }

    var execution: PhysicalTypingExecution {
        .init(text: text, finalLayoutID: activeLayoutID, transactions: transactions, observations: observations, decisions: decisions)
    }

    mutating func apply(_ action: PhysicalTypingAction, at index: Int) throws {
        let before = activeLayoutID
        var produced = ""
        switch action.kind {
        case .selectLayout:
            if let id = action.layoutID {
                activeLayoutID = id
                translation.reset()
            }
        case .keyUp:
            break
        case .keyDown:
            guard let keyCode = action.keyCode else { throw PhysicalTypingError.invalidScenario("missing keycode") }
            switch keyCode {
            case 51:
                if !text.isEmpty { text.removeLast() }
                input.handle(.plainBackspace)
            case 36, 48:
                let boundary: InputBoundary = keyCode == 36 ? .enter : .tab
                produced = boundary.text
                try finish(boundary, at: index)
                // Initial runner supports a multiline text editor only, not Tab
                // focus changes or Enter submitting a composer.
                input.invalidate(clearContext: true)
                translation.reset()
            default:
                let layout = try layouts.layout(activeLayoutID)
                guard let value = translation.translate(
                    keyCode: keyCode, shift: action.shift, capsLock: action.capsLock,
                    layoutData: layout.data, keyboardType: stimulus.keyboardType
                ) else { throw PhysicalTypingError.unsupportedAction(index, "keyboard translation failed") }
                produced = value
                if InputEventClassifier.classifySpaceKey(isSpaceKey: keyCode == 49, producedText: value) == .boundary {
                    try finish(.space(count: 1), at: index)
                } else {
                    // Production dead-key reconciliation is not shared here yet.
                    // Reject its auto-conversion path instead of reporting parity.
                    if !faults.disableAutomaticConversion, value.isEmpty || keyCode == 49 {
                        throw PhysicalTypingError.unsupportedAction(index, "automatic dead-key composition")
                    }
                    text += value
                    input.handle(.printable(TypedKey(
                        keyCode: keyCode, shift: action.shift, caps: action.capsLock,
                        producedText: value, sourceLayoutID: activeLayoutID
                    )))
                }
            }
        }
        observations.append(.init(
            actionIndex: index, atMicroseconds: action.atMicroseconds,
            layoutIDBefore: before, layoutIDAfter: activeLayoutID,
            producedText: produced, textAfter: text
        ))
    }

    private mutating func finish(_ boundary: InputBoundary, at index: Int) throws {
        guard let snapshot = input.snapshot(boundary: boundary, focus: focus),
              let original = snapshot.producedText else {
            text += boundary.text
            input.handle(.boundary(boundary))
            return
        }
        let sourceID = snapshot.sourceLayoutID
        guard let sourceID, sourceID == activeLayoutID,
              let targetID = stimulus.layoutIDs.first(where: { $0 != sourceID }),
              !faults.disableAutomaticConversion else {
            text += boundary.text
            input.complete(resolvedText: original, language: SmartTokenizer.languageHint(for: original), wasConverted: false)
            return
        }
        let source = try layouts.layout(sourceID)
        let target = try layouts.layout(targetID)
        var converted = ""
        for key in snapshot.keys {
            let value = try layouts.character(
                keyCode: key.keyCode, shift: key.shift, capsLock: key.caps,
                layoutID: targetID, keyboardType: stimulus.keyboardType
            )
            guard !value.isEmpty else { throw PhysicalTypingError.unsupportedAction(index, "target dead-key composition") }
            converted += value
        }
        let decision = LayoutDecoder.evaluate(
            typed: original, converted: converted,
            currentLanguage: source.language, targetLanguage: target.language,
            capsLock: snapshot.keys.contains(where: \.caps),
            contextWords: snapshot.context.map(\.text), languageBelief: snapshot.languageBelief,
            integrity: snapshot.integrity, policy: .empty, model: model
        ).decision
        decisions.append(.init(actionIndex: index, original: original, replacement: decision.candidate.replacement,
                               verdict: String(describing: decision.verdict), reason: String(describing: decision.reason)))
        guard decision.verdict == .switchToConverted, text.hasSuffix(original) else {
            text += boundary.text
            input.complete(resolvedText: original, language: source.language, wasConverted: false)
            return
        }
        let transaction = ConversionTransaction(
            original: original, replacement: decision.candidate.replacement, boundary: boundary,
            focus: focus, sourceLayoutID: sourceID, targetLayoutID: targetID,
            sequence: snapshot.sequence, editRevision: snapshot.editRevision,
            createdAt: Date(timeIntervalSince1970: 0), automatic: true
        )
        let plan = EventReplacementPlan(transaction: transaction, deliveredKeyCount: snapshot.deliveredKeyCount)
        for _ in 0..<plan.backspaceCount where !text.isEmpty { text.removeLast() }
        if !faults.dropInsertion { text += plan.replacementText }
        if faults.duplicateInsertion { text += plan.replacementText }
        text += plan.replayText
        transactions += 1
        if !faults.disableLayoutSwitch {
            activeLayoutID = targetID
            translation.reset()
        }
        input.complete(resolvedText: transaction.replacement, language: target.language, wasConverted: true)
    }
}
