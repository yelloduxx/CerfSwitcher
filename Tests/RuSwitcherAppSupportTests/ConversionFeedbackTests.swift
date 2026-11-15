import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

final class ConversionFeedbackTests: XCTestCase {
    func testPostDoesNotClaimVerifiedReplacement() {
        XCTAssertEqual(ConversionAttemptResult(outcome: .postedUnverified), .unverified)
        XCTAssertEqual(ConversionAttemptResult(outcome: .verified), .converted)
        XCTAssertEqual(ConversionAttemptResult(outcome: .failed(.verificationMismatch)),
                       .refused(.verificationFailed))
    }

    func testActualRefusalReasonsRemainDistinct() {
        XCTAssertEqual(ConversionAttemptResult(outcome: .blocked(.contextUnavailable)),
                       .refused(.fieldUnavailable))
        XCTAssertEqual(ConversionAttemptResult(outcome: .blocked(.deniedApplication)),
                       .refused(.excludedApplication))
        XCTAssertEqual(ConversionAttemptResult(outcome: .blocked(.expectedSuffixMismatch)),
                       .refused(.editorChanged))
        XCTAssertEqual(ConversionAttemptResult(keptBecause: .undecided), .refused(.uncertain))
        XCTAssertEqual(ConversionAttemptResult(keptBecause: .blockedContext), .refused(.uncertain))
        XCTAssertEqual(ConversionAttemptResult(keptBecause: .blockedNever), .refused(.wordRule))
        XCTAssertEqual(ConversionAttemptResult(keptBecause: .keepCurrentWord), .kept)
    }

    func testLateReadbackCannotReplaceNewerManualResult() {
        var feedback = ConversionFeedback()
        let automatic = feedback.begin(.automatic)
        XCTAssertTrue(feedback.record(.unverified, for: automatic))
        let manual = feedback.begin(.manual)
        XCTAssertTrue(feedback.record(.refused(.busy), for: manual))
        XCTAssertFalse(feedback.record(.converted, for: automatic))
        XCTAssertEqual(feedback.latest?.result, .refused(.busy))
        XCTAssertEqual(feedback.latest?.attempt.source, .manual)
    }

    func testConfirmationUpdatesOnlyItsOwnAttempt() {
        var feedback = ConversionFeedback()
        let attempt = feedback.begin(.automatic)
        feedback.record(.unverified, for: attempt)
        XCTAssertTrue(feedback.record(.converted, for: attempt))
        XCTAssertEqual(feedback.latest?.result, .converted)
        feedback.clear()
        XCTAssertFalse(feedback.record(.unverified, for: attempt))
        XCTAssertNil(feedback.latest)
    }

    func testPauseInvalidatesPendingWorkButPreservesLastResult() {
        var feedback = ConversionFeedback()
        let attempt = feedback.begin(.manual)
        feedback.record(.unverified, for: attempt)
        feedback.invalidatePending()
        XCTAssertFalse(feedback.isCurrent(attempt))
        XCTAssertFalse(feedback.record(.converted, for: attempt))
        XCTAssertEqual(feedback.latest?.result, .unverified)
        let next = feedback.begin(.manual)
        XCTAssertTrue(feedback.isCurrent(next))
    }
}
