import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

public struct PhysicalTypingFaults: Equatable, Sendable {
    public var disableAutomaticConversion = false
    public var disableLayoutSwitch = false
    public var dropInsertion = false
    public var duplicateInsertion = false
    public var dropFirstBackspace = false
    public var rejectPost = false
    public var preflightUnavailable = false
    public var verificationUnavailable = false
    public var duplicateAcknowledgement = false
    public var disableQueuedLayoutSynchronization = false

    public init() {}
}

public struct PhysicalTypingObservation: Codable, Equatable, Sendable {
    public let actionIndex: Int
    public let atMicroseconds: UInt64
    public let processedAtMicroseconds: UInt64
    public let capturedLayoutID: String
    public let capturedText: String
    public let layoutIDBefore: String
    public let layoutIDAfter: String
    public let producedText: String
    public let textAfter: String
    public let deliveredText: String
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
    public let trace: [PhysicalTypingTrace]
    public let editors: [String: PhysicalTypingEditorState]
    public let verifiedCompletions: Int
    public let context: [String]
    public let timing: PhysicalTypingTiming
    public let focusedFieldID: String
}

public struct PhysicalTypingEditorState: Codable, Equatable, Sendable {
    public let text: String
    public let selectedRange: NSRange
    public let revision: UInt64
}

public struct PhysicalTypingTrace: Codable, Equatable, Sendable {
    public let atMicroseconds: UInt64
    public let event: String
    public let actionIndex: Int
    public let transactionSequence: UInt64?
    public let fieldID: String
    public let editor: PhysicalTypingEditorState
    public let layoutID: String
    public let inputSequence: UInt64
    public let editRevision: UInt64
    public let context: [String]
}

public struct PhysicalTypingAssessment: Codable, Equatable, Sendable {
    public let passed: Bool
    public let failures: [String]

    public static func assess(_ execution: PhysicalTypingExecution, oracle: PhysicalTypingOracle) -> Self {
        var failures: [String] = []
        if execution.text != oracle.text { failures.append("text-mismatch") }
        if execution.finalLayoutID != oracle.finalLayoutID { failures.append("final-layout-mismatch") }
        if execution.transactions != oracle.transactions { failures.append("transaction-count-mismatch") }
        if let selectedRange = oracle.selectedRange,
           execution.editors[execution.focusedFieldID]?.selectedRange != selectedRange {
            failures.append("selection-mismatch")
        }
        if let count = oracle.verifiedCompletions, execution.verifiedCompletions != count {
            failures.append("verified-completion-count-mismatch")
        }
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

/// Closed-loop physical translation, with production classification and the
/// replacement driver running against scheduled editor/AX transport fakes.
/// The runner deliberately has no access to a fixture's expected output.
@MainActor
public struct PhysicalTypingRunner {
    private let layouts: SystemTypingLayouts
    private let model: LanguageModelStore

    public init(layouts: SystemTypingLayouts, model: LanguageModelStore) {
        self.layouts = layouts
        self.model = model
    }

    public func run(_ stimulus: PhysicalTypingStimulus, faults: PhysicalTypingFaults = .init()) throws -> PhysicalTypingExecution {
        try validate(stimulus)
        let session = PhysicalTypingSession(stimulus: stimulus, layouts: layouts, model: model, faults: faults)
        for (index, action) in stimulus.actions.enumerated() {
            session.clock.schedule(at: action.atMicroseconds) {
                guard session.error == nil else { return }
                do { try session.receive(action, at: index) }
                catch { session.error = error }
            }
        }
        session.clock.drain()
        if let error = session.error { throw error }
        guard session.finishedAllInput else { throw PhysicalTypingError.invalidScenario("incomplete callback queue") }
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
        let timing = stimulus.timing ?? .init()
        guard [timing.deliveryDelayMicroseconds, timing.syntheticEventIntervalMicroseconds,
               timing.layoutDelayMicroseconds, timing.verificationReadDelayMicroseconds,
               timing.acknowledgementDelayMicroseconds, timing.conversionPrePostMicroseconds,
               timing.conversionPostWorkMicroseconds].allSatisfy({ $0 <= 1_000_000 }),
              stimulus.actions.count <= 100_000 else {
            throw PhysicalTypingError.invalidScenario("timing or action limit exceeded")
        }
        for (index, action) in stimulus.actions.enumerated() {
            guard action.atMicroseconds >= lastTime, action.atMicroseconds <= 86_400_000_000 else {
                throw PhysicalTypingError.invalidScenario("event times must be monotonic")
            }
            lastTime = action.atMicroseconds
            switch action.kind {
            case .selectLayout:
                guard let id = action.layoutID, stimulus.layoutIDs.contains(id),
                      action.keyCode == nil, action.fieldID == nil, !action.autorepeat,
                      !action.shift, !action.capsLock, !action.command, !action.control, !action.option else {
                    throw PhysicalTypingError.invalidScenario("invalid layout action at \(index)")
                }
            case .focusChange, .tapRecovery:
                guard action.keyCode == nil, action.layoutID == nil, !action.autorepeat,
                      !action.shift, !action.capsLock, !action.command, !action.control, !action.option,
                      action.kind == .focusChange ? action.fieldID?.isEmpty == false : action.fieldID == nil else {
                    throw PhysicalTypingError.invalidScenario("invalid lifecycle action at \(index)")
                }
            case .keyDown, .keyUp:
                guard let code = action.keyCode, action.layoutID == nil, action.fieldID == nil else {
                    throw PhysicalTypingError.invalidScenario("missing keycode at \(index)")
                }
                guard KeyMapping.keycodeToEN[code] != nil || [36, 48, 49, 51, 123, 124].contains(code) else {
                    throw PhysicalTypingError.unsupportedAction(index, "keycode \(code)")
                }
                // Host command semantics differ. Do not silently model an
                // arbitrary shortcut as ordinary text or pretend it is tested.
                guard !action.command, !action.control, !action.option else {
                    throw PhysicalTypingError.unsupportedAction(index, "modified host editing command")
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

@MainActor
private final class PhysicalTypingSession {
    let stimulus: PhysicalTypingStimulus
    let layouts: SystemTypingLayouts
    let model: LanguageModelStore
    let faults: PhysicalTypingFaults
    let clock = VirtualEventScheduler()
    var error: Error?
    let timing: PhysicalTypingTiming
    private var activeLayoutID: String
    private var translation = KeyboardLayoutTranslationState()
    private var translationLayoutID: String?
    private var arrivalTranslation = KeyboardLayoutTranslationState()
    private var arrivalTranslationLayoutID: String?
    private var queuedLayoutTransition = QueuedLayoutTransition()
    private lazy var callbackQueue = VirtualCallbackQueue(clock: clock)
    private var input = InputSession(contextLimit: InputContextLimits.maximumTokens)
    private var fieldID = "editor"
    private var editors = ["editor": VirtualTextEditor()]
    private var transactions = 0
    private var verifiedCompletions = 0
    private var observations: [Int: PhysicalTypingObservation] = [:]
    private var decisions: [PhysicalTypingDecision] = []
    private var trace: [PhysicalTypingTrace] = []
    private var currentActionIndex = 0
    private var postedTransactionSequence: UInt64?
    private lazy var transport = ScheduledEditorTransport(session: self)
    private lazy var driver = AutomaticReplacementDriver(
        coordinator: NativeReplacementCoordinator(reader: transport, poster: transport), scheduler: callbackQueue
    )
    private var focus: FocusedElementIdentity {
        .init(processID: 1, bundleID: "com.ruswitcher.physical-test", identifier: fieldID)
    }
    private var editor: VirtualTextEditor {
        get { editors[fieldID] ?? VirtualTextEditor() }
        set { editors[fieldID] = newValue }
    }

    init(stimulus: PhysicalTypingStimulus, layouts: SystemTypingLayouts, model: LanguageModelStore, faults: PhysicalTypingFaults) {
        self.stimulus = stimulus
        self.layouts = layouts
        self.model = model
        self.faults = faults
        self.activeLayoutID = stimulus.initialLayoutID
        self.timing = stimulus.timing ?? .init()
    }

    var execution: PhysicalTypingExecution {
        .init(text: editor.text, finalLayoutID: activeLayoutID, transactions: transactions,
              observations: observations.sorted { $0.key < $1.key }.map(\.value), decisions: decisions, trace: trace,
              editors: editors.mapValues(Self.editorState), verifiedCompletions: verifiedCompletions,
              context: input.context.map(\.text), timing: timing, focusedFieldID: fieldID)
    }

    var finishedAllInput: Bool { callbackQueue.isIdle && observations.count == stimulus.actions.count }

    func receive(_ action: PhysicalTypingAction, at index: Int) throws {
        let capturedLayoutID = activeLayoutID
        if arrivalTranslationLayoutID != activeLayoutID {
            arrivalTranslation.reset()
            arrivalTranslationLayoutID = activeLayoutID
        }
        let capturedText = try producedText(action, layoutID: activeLayoutID, translator: &arrivalTranslation, index: index)
        if action.kind == .keyDown, let keyCode = action.keyCode,
           KeyMapping.keycodeToEN[keyCode] != nil || keyCode == 49,
           capturedText.isEmpty, !faults.disableAutomaticConversion {
            throw PhysicalTypingError.unsupportedAction(index, "automatic dead-key composition")
        }
        // Explicit source/focus actions affect the environment immediately;
        // session invalidation still waits for its turn on the callback lane.
        if action.kind == .selectLayout, let id = action.layoutID {
            activeLayoutID = id
            queuedLayoutTransition.reset()
        }
        if action.kind == .focusChange, let id = action.fieldID {
            fieldID = id
            if editors[id] == nil { editors[id] = VirtualTextEditor() }
        }
        record("input-arrived", actionIndex: index)
        callbackQueue.perform { [self] done in
            guard error == nil else { done(); return }
            do { try apply(action, at: index, capturedLayoutID: capturedLayoutID, capturedText: capturedText, done: done) }
            catch { self.error = error; done() }
        }
    }

    private func producedText(_ action: PhysicalTypingAction, layoutID: String,
                              translator: inout KeyboardLayoutTranslationState, index: Int) throws -> String {
        guard action.kind == .keyDown, let keyCode = action.keyCode else { return "" }
        if keyCode == 36 { return "\n" }
        if keyCode == 48 { return "\t" }
        guard KeyMapping.keycodeToEN[keyCode] != nil || keyCode == 49 else { return "" }
        let layout = try layouts.layout(layoutID)
        guard let value = translator.translate(keyCode: keyCode, shift: action.shift, capsLock: action.capsLock,
                                               layoutData: layout.data, keyboardType: stimulus.keyboardType) else {
            throw PhysicalTypingError.unsupportedAction(index, "keyboard translation failed")
        }
        return value
    }

    private func apply(_ action: PhysicalTypingAction, at index: Int, capturedLayoutID: String, capturedText: String,
                       done: @escaping @MainActor () -> Void) throws {
        currentActionIndex = index
        let before = activeLayoutID
        let began = clock.now
        var produced = ""
        var delivered = ""
        record("callback-began", actionIndex: index)
        func finished() {
            observations[index] = .init(
                actionIndex: index, atMicroseconds: action.atMicroseconds, processedAtMicroseconds: began,
                capturedLayoutID: capturedLayoutID, capturedText: capturedText,
                layoutIDBefore: before, layoutIDAfter: activeLayoutID,
                producedText: produced, textAfter: editor.text, deliveredText: delivered
            )
            record("user-\(action.kind.rawValue)", actionIndex: index)
            record("callback-ended", actionIndex: index)
            done()
        }
        switch action.kind {
        case .selectLayout:
            translation.reset()
        case .focusChange:
            input.handle(.focusChanged)
            translation.reset()
            queuedLayoutTransition.reset()
        case .tapRecovery:
            input.handle(.tapRecovered)
            translation.reset()
            queuedLayoutTransition.reset()
        case .keyUp:
            break
        case .keyDown:
            guard let keyCode = action.keyCode else { throw PhysicalTypingError.invalidScenario("missing keycode") }
            if translationLayoutID != activeLayoutID {
                translation.reset()
                translationLayoutID = activeLayoutID
            }
            produced = try producedText(action, layoutID: activeLayoutID, translator: &translation, index: index)
            delivered = capturedText
            let key = TypedKey(keyCode: keyCode, shift: action.shift, caps: action.capsLock,
                               producedText: produced, sourceLayoutID: activeLayoutID)
            let disposition = InputEventClassifier.classifyLocalKeyDown(
                key: key, command: action.command, control: action.control, option: action.option
            )
            switch disposition {
            case let .boundary(boundary):
                try finish(boundary, at: index) { [self] in
                    if keyCode == 36 || keyCode == 48 {
                        // This host inserts Enter/Tab; it does not send or move focus.
                        // Only pass-through boundaries clear the staged session.
                        if !lastBoundaryConsumed { input.reset() }
                        translation.reset()
                        queuedLayoutTransition.reset()
                    }
                    delivered = lastBoundaryConsumed ? "" : boundary.text
                    finished()
                }
                return
            case .compositionCommit:
                guard faults.disableAutomaticConversion else {
                    throw PhysicalTypingError.unsupportedAction(index, "automatic dead-key composition")
                }
                editor.insert(delivered)
                queuedLayoutTransition.reset()
            case .printable:
                if produced.isEmpty, !faults.disableAutomaticConversion {
                    throw PhysicalTypingError.unsupportedAction(index, "automatic dead-key composition")
                }
                if !faults.disableQueuedLayoutSynchronization,
                   let override = queuedLayoutTransition.overrideText(
                    eventTimestamp: action.atMicroseconds * 1_000, layoutID: activeLayoutID, translatedText: produced
                   ) {
                    delivered = override
                    if delivered != capturedText { record("queued-layout-retranslated", actionIndex: index) }
                }
                editor.insert(delivered)
                input.handle(.printable(key))
            case let .editing(event):
                input.handle(event)
                queuedLayoutTransition.reset()
                delivered = ""
                if event == .plainBackspace { editor.backspace() }
                else if keyCode == 123 || keyCode == 124 {
                    editor.moveCaret(byCharacters: keyCode == 123 ? -1 : 1, extendingSelection: action.shift)
                } else { throw PhysicalTypingError.unsupportedAction(index, "host editing semantics") }
            }
        }
        finished()
    }

    private var lastBoundaryConsumed = false

    private func finish(_ boundary: InputBoundary, at index: Int, done: @escaping @MainActor () -> Void) throws {
        lastBoundaryConsumed = false
        guard let snapshot = input.snapshot(boundary: boundary, focus: focus),
              let original = snapshot.producedText else {
            editor.insert(boundary.text)
            input.handle(.boundary(boundary))
            done()
            return
        }
        let sourceID = snapshot.sourceLayoutID
        guard let sourceID, sourceID == activeLayoutID,
              let targetID = stimulus.layoutIDs.first(where: { $0 != sourceID }),
              !faults.disableAutomaticConversion else {
            editor.insert(boundary.text)
            input.applyTokenHandlingResult(.passThrough, snapshot: snapshot)
            done()
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
        let plan = AutomaticConversionPlanner.prepare(
            snapshot: snapshot, original: original, converted: converted,
            currentLanguage: source.language, targetLanguage: target.language,
            targetLayoutID: targetID, model: model,
            at: Date(timeIntervalSince1970: Double(clock.now) / 1_000_000)
        )
        if let decision = plan.evaluation?.decision {
            decisions.append(.init(actionIndex: index, original: original, replacement: decision.candidate.replacement,
                                   verdict: String(describing: decision.verdict), reason: String(describing: decision.reason)))
        }
        let request: ReplacementRequest
        switch plan {
        case let .keep(handling, _):
            editor.insert(boundary.text)
            input.applyTokenHandlingResult(handling, snapshot: snapshot)
            done()
            return
        case let .replace(prepared, _): request = prepared
        }
        after(timing.conversionPrePostMicroseconds) { [self] in
            submit(request, snapshot: snapshot, sourceLanguage: source.language, targetLanguage: target.language,
                   boundary: boundary, index: index, done: done)
        }
    }

    private func after(_ delay: UInt64, _ action: @escaping @MainActor () -> Void) {
        if delay == 0 { action() }
        else { clock.schedule(at: clock.now + delay, action) }
    }

    private func submit(_ request: ReplacementRequest, snapshot: TokenSnapshot, sourceLanguage: String,
                        targetLanguage: String, boundary: InputBoundary, index: Int,
                        done: @escaping @MainActor () -> Void) {
        let transaction = request.transaction
        postedTransactionSequence = transaction.sequence
        let submission = driver.submit(
            request,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
            switchLayout: { [unowned self] id in requestLayout(id, actionIndex: index, sequence: transaction.sequence) }
        ) { [weak self] outcome in
            self?.complete(outcome, transaction: transaction, language: targetLanguage, actionIndex: index)
        }
        lastBoundaryConsumed = submission.handling.consumeBoundary
        record("submit-\(submission.outcome)", actionIndex: index, sequence: transaction.sequence)
        after(submission.isNewPost ? timing.conversionPostWorkMicroseconds : 0) { [self] in
            input.applyTokenHandlingResult(submission.handling, snapshot: snapshot)
            if !lastBoundaryConsumed { editor.insert(boundary.text) }
            done()
        }
    }

    private func requestLayout(_ id: String?, actionIndex: Int, sequence: UInt64) {
        guard let id, !faults.disableLayoutSwitch else { return }
        let apply: @MainActor () -> Void = { [unowned self] in
            activeLayoutID = id
            translation.reset()
            if !faults.disableQueuedLayoutSynchronization {
                queuedLayoutTransition.record(targetLayoutID: id, completedAt: clock.now * 1_000)
            }
            record("layout-delivered", actionIndex: actionIndex, sequence: sequence)
        }
        after(timing.layoutDelayMicroseconds + timing.conversionPostWorkMicroseconds, apply)
    }

    private func complete(_ outcome: ReplacementOutcome, transaction: ConversionTransaction,
                          language: String, actionIndex: Int) {
        let result = AutomaticReplacementDriver.completion(
            for: outcome, transaction: transaction,
            state: .init(focus: focus, sequence: input.sequence, editRevision: input.editRevision,
                         integrity: input.integrity, hasCurrentToken: !input.currentKeys.isEmpty)
        )
        switch result {
        case .confirm:
            if input.confirmStagedCompletion(resolvedText: transaction.replacement, language: language,
                                             wasConverted: true, expectedSequence: transaction.sequence &+ 1) {
                verifiedCompletions += 1
            }
        case .discard, .invalidate:
            if input.sequence == transaction.sequence &+ 1, input.currentKeys.isEmpty {
                input.invalidate(clearContext: true)
            }
        case .retainUnverified, .ignore:
            break
        }
        record("completion-\(result)", actionIndex: actionIndex, sequence: transaction.sequence)
    }

    fileprivate func validate(_ expected: String, focus expectedFocus: FocusedElementIdentity) -> TextContextPreflight {
        if faults.preflightUnavailable { return .unavailable }
        guard focus == expectedFocus else { return .mismatch }
        let caret = editor.selectedRange
        guard caret.length == 0, caret.location >= expected.utf16.count else { return .mismatch }
        let start = max(0, caret.location - expected.utf16.count - TextReplacementAnchor.maximumPrefixUTF16Length)
        let range = NSRange(location: start, length: caret.location - start)
        return TextReplacementAnchor.capture(expectedSuffix: expected, focus: focus, selection: caret,
                                             capturedRange: range, capturedText: (editor.text as NSString).substring(with: range))
    }

    private func compare(_ expected: String, anchor: TextReplacementAnchor) -> TextContextValidation {
        guard focus == anchor.focus, editor.selectedRange == anchor.expectedSelection(replacement: expected) else { return .mismatch }
        guard let range = anchor.expectedRange(replacement: expected),
              range.location <= editor.text.utf16.count,
              range.length <= editor.text.utf16.count - range.location else { return .unavailable }
        return anchor.verify(replacement: expected, focus: focus, selection: editor.selectedRange,
                             capturedRange: range, capturedText: (editor.text as NSString).substring(with: range))
    }

    fileprivate func post(_ plan: EventReplacementPlan, processID: Int32) -> Bool {
        guard !faults.rejectPost, processID == focus.processID else { return false }
        transactions += 1
        let actionIndex = currentActionIndex
        let sequence = postedTransactionSequence
        var eventOffset: UInt64 = 0
        func schedule(_ category: String, _ action: @escaping @MainActor (PhysicalTypingSession) -> Void) {
            let at = clock.now + timing.deliveryDelayMicroseconds + eventOffset * timing.syntheticEventIntervalMicroseconds
            eventOffset += 1
            clock.schedule(at: at) { [weak self] in
                guard let self else { return }
                action(self)
                // Marked synthetic events mutate the editor only, never InputSession.
                self.record(category, actionIndex: actionIndex, sequence: sequence)
            }
        }
        for index in 0..<plan.backspaceCount {
            schedule(index == 0 && faults.dropFirstBackspace ? "synthetic-backspace-dropped" : "synthetic-backspace") {
                if !(index == 0 && $0.faults.dropFirstBackspace) { $0.editor.backspace() }
            }
            schedule("synthetic-keyUp") { _ in }
        }
        schedule(faults.dropInsertion ? "synthetic-insertion-dropped" : "synthetic-insertion") {
            if !$0.faults.dropInsertion { $0.editor.insert(plan.replacementText) }
        }
        schedule("synthetic-keyUp") { _ in }
        if faults.duplicateInsertion { schedule("synthetic-insertion-duplicate") { $0.editor.insert(plan.replacementText) } }
        if !plan.replayText.isEmpty {
            schedule("synthetic-boundary") { $0.editor.insert(plan.replayText) }
            schedule("synthetic-keyUp") { _ in }
        }
        return true
    }

    fileprivate func verify(_ expected: String, anchor: TextReplacementAnchor, deadlineMilliseconds: Int,
                            completion: @escaping @MainActor (TextContextValidation) -> Void) {
        let start = clock.now
        let deadline = start + UInt64(deadlineMilliseconds) * 1_000
        let actionIndex = currentActionIndex
        let sequence = postedTransactionSequence
        guard timing.verificationReadDelayMicroseconds <= UInt64(deadlineMilliseconds) * 1_000 else {
            clock.schedule(at: deadline) { [weak self] in
                guard let self else { return }
                self.record("readback-timeout", actionIndex: actionIndex, sequence: sequence)
                self.clock.schedule(at: self.clock.now + self.timing.acknowledgementDelayMicroseconds) {
                    completion(.unavailable)
                }
            }
            return
        }
        pollVerification(expected, anchor: anchor,
                         at: start + timing.verificationReadDelayMicroseconds, deadline: deadline,
                         actionIndex: actionIndex, sequence: sequence, completion: completion)
    }

    private func pollVerification(_ expected: String, anchor: TextReplacementAnchor,
                                  at time: UInt64, deadline: UInt64, actionIndex: Int, sequence: UInt64?,
                                  completion: @escaping @MainActor (TextContextValidation) -> Void) {
        clock.schedule(at: time) { [weak self] in
            guard let self else { return }
            let result: TextContextValidation = self.faults.verificationUnavailable ? .unavailable : self.compare(expected, anchor: anchor)
            self.record("readback-\(result)", actionIndex: actionIndex, sequence: sequence)
            if result == .match || self.clock.now == deadline {
                self.clock.schedule(at: self.clock.now + self.timing.acknowledgementDelayMicroseconds) {
                    completion(result)
                    if self.faults.duplicateAcknowledgement { completion(result) }
                }
            } else {
                self.pollVerification(expected, anchor: anchor, at: min(self.clock.now + 1_000, deadline),
                                      deadline: deadline, actionIndex: actionIndex, sequence: sequence, completion: completion)
            }
        }
    }

    private static func editorState(_ editor: VirtualTextEditor) -> PhysicalTypingEditorState {
        .init(text: editor.text, selectedRange: editor.selectedRange, revision: editor.revision)
    }

    private func record(_ event: String, actionIndex: Int, sequence: UInt64? = nil) {
        trace.append(.init(atMicroseconds: clock.now, event: event, actionIndex: actionIndex,
                           transactionSequence: sequence, fieldID: fieldID, editor: Self.editorState(editor),
                           layoutID: activeLayoutID, inputSequence: input.sequence,
                           editRevision: input.editRevision, context: input.context.map(\.text)))
    }
}

@MainActor
private final class ScheduledEditorTransport: FocusedTextContextReading, KeyboardEventPosting {
    private unowned let session: PhysicalTypingSession
    init(session: PhysicalTypingSession) { self.session = session }

    func validate(expectedSuffix: String, focus: FocusedElementIdentity, deadlineMilliseconds: Int) -> TextContextPreflight {
        session.validate(expectedSuffix, focus: focus)
    }

    func verify(expectedSuffix: String, anchor: TextReplacementAnchor, deadlineMilliseconds: Int,
                completion: @escaping @MainActor (TextContextValidation) -> Void) {
        session.verify(expectedSuffix, anchor: anchor, deadlineMilliseconds: deadlineMilliseconds, completion: completion)
    }

    func post(_ plan: EventReplacementPlan, to processID: Int32, delivery: KeyboardEventDelivery) -> Bool {
        session.post(plan, processID: processID)
    }
}
