import XCTest
@testable import RuSwitcherCore

final class DeferredManualLearningGateTests: XCTestCase {
    func testContinuationCapturesOnlyTheCandidatePresentAtInputTime() throws {
        var gate = DeferredManualLearningGate()
        XCTAssertNil(gate.pendingGeneration)
        gate.stage(.init(original: "one", converted: "щту", appBundleID: "editor.one"))
        let captured = try XCTUnwrap(gate.pendingGeneration)
        gate.cancel()
        gate.stage(.init(original: "two", converted: "ецщ", appBundleID: "editor.two"))
        XCTAssertNil(gate.accept(expectedGeneration: captured))
        XCTAssertTrue(gate.hasPendingCandidate)
        let current = try XCTUnwrap(gate.pendingGeneration)
        XCTAssertEqual(gate.accept(expectedGeneration: current)?.original, "two")
        XCTAssertNil(gate.pendingGeneration)
    }

    func testContinuationAcceptsPostedManualCorrection() {
        var gate = DeferredManualLearningGate()
        let candidate = DeferredManualLearningCandidate(
            original: "лкуф",
            converted: "krea",
            appBundleID: "editor.example"
        )

        let generation = gate.stage(candidate)

        XCTAssertTrue(gate.hasPendingCandidate)
        XCTAssertEqual(gate.accept(expectedGeneration: generation), candidate)
        XCTAssertFalse(gate.hasPendingCandidate)
    }

    func testReversalCancelsPostedManualCorrection() {
        var gate = DeferredManualLearningGate()
        let generation = gate.stage(DeferredManualLearningCandidate(
            original: "лкуф",
            converted: "krea",
            appBundleID: nil
        ))

        gate.cancel()

        XCTAssertNil(gate.accept(expectedGeneration: generation))
        XCTAssertFalse(gate.hasPendingCandidate)
    }

    func testStaleTimerCannotAcceptNewerCorrection() {
        var gate = DeferredManualLearningGate()
        let firstGeneration = gate.stage(DeferredManualLearningCandidate(
            original: "лкуф",
            converted: "krea",
            appBundleID: nil
        ))
        let second = DeferredManualLearningCandidate(
            original: "руддщ",
            converted: "hello",
            appBundleID: nil
        )
        let secondGeneration = gate.stage(second)

        XCTAssertNil(gate.accept(expectedGeneration: firstGeneration))
        XCTAssertEqual(gate.accept(expectedGeneration: secondGeneration), second)
    }
}
