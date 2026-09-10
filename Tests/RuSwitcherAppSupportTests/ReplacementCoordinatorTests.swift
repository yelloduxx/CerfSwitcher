import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

@MainActor
final class ReplacementCoordinatorTests: XCTestCase {
    func testPostingIsUnverifiedUntilReadbackMatches() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        var completions: [ReplacementOutcome] = []

        let initial = coordinator.submit(request()) { completions.append($0) }

        XCTAssertEqual(initial, .postedUnverified)
        XCTAssertEqual(poster.plans.count, 1)
        XCTAssertEqual(poster.deliveries, [.targetedProcess])
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(
            reader.validationDeadlines,
            [ReplacementTiming.preflightDeadlineMilliseconds]
        )
        XCTAssertEqual(
            reader.verificationDeadlines,
            [ReplacementTiming.postedEventVerificationDeadlineMilliseconds]
        )

        reader.complete(.match)
        XCTAssertEqual(completions, [.verified])
    }

    func testAcceptedPostWithUnavailableReadbackNeverBecomesVerified() {
        let reader = Reader(preflight: .match)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: Poster(result: true))
        var completion: ReplacementOutcome?

        XCTAssertEqual(coordinator.submit(request()) { completion = $0 }, .postedUnverified)
        reader.complete(.unavailable)

        XCTAssertEqual(completion, .postedUnverified)
    }

    func testMismatchBeforePostingBlocksTransaction() {
        let reader = Reader(preflight: .mismatch)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        let outcome = coordinator.submit(request()) { _ in XCTFail("must not verify") }

        XCTAssertEqual(outcome, .blocked(.expectedSuffixMismatch))
        XCTAssertTrue(poster.plans.isEmpty)
    }

    func testUnavailablePreflightBlocksWithoutOptIn() {
        let reader = Reader(preflight: .unavailable)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        XCTAssertEqual(
            coordinator.submit(request()) { _ in XCTFail("must not verify") },
            .blocked(.contextUnavailable)
        )
        XCTAssertTrue(poster.plans.isEmpty)
    }

    func testUnavailablePreflightPostsWhenOptedIn() {
        let reader = Reader(preflight: .unavailable)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        var completion: ReplacementOutcome?

        let outcome = coordinator.submit(
            request(allowUnavailablePost: true)
        ) { completion = $0 }

        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(poster.plans.count, 1)
        XCTAssertEqual(poster.deliveries, [.globalEventStream])
        // No preflight anchor means no later suffix-only "upgrade", even if
        // the host becomes readable after publication.
        XCTAssertTrue(reader.verificationDeadlines.isEmpty)
        reader.complete(.match)
        XCTAssertEqual(completion, .postedUnverified)
    }

    func testMismatchStillBlocksEvenWhenOptedIn() {
        let reader = Reader(preflight: .mismatch)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        XCTAssertEqual(
            coordinator.submit(request(allowUnavailablePost: true)) { _ in XCTFail("must not verify") },
            .blocked(.expectedSuffixMismatch)
        )
        XCTAssertTrue(poster.plans.isEmpty)
    }

    func testOptInStillHonorsFocusAndRevisionGates() {
        let reader = Reader(preflight: .unavailable)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        // Revision drifted since the token was typed: freshness gate must win
        // even with the opt-in, because that gate is the only safety left.
        let stale = request(allowUnavailablePost: true, currentRevision: 4)
        XCTAssertEqual(
            coordinator.submit(stale) { _ in XCTFail("must not verify") },
            .blocked(.staleRevision)
        )
        XCTAssertTrue(poster.plans.isEmpty)
    }

    func testDuplicateTransactionIsNeverPostedTwice() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        let request = request()

        XCTAssertEqual(coordinator.submit(request) { _ in }, .postedUnverified)
        XCTAssertEqual(coordinator.submit(request) { _ in }, .blocked(.duplicateTransaction))
        XCTAssertEqual(poster.plans.count, 1)
    }

    func testAnchorFromAnotherFieldBlocksEvenWhenTheOriginalSuffixMatches() {
        let reader = Reader(preflight: .match)
        reader.focusOverride = .init(processID: 42, bundleID: "test.host", identifier: "other-field")
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        XCTAssertEqual(coordinator.submit(request()) { _ in XCTFail("must not verify another field") }, .blocked(.invalidFocus))
        XCTAssertTrue(poster.plans.isEmpty)
    }

    private func request(
        allowUnavailablePost: Bool = false,
        currentRevision: UInt64 = 3
    ) -> ReplacementRequest {
        let focus = FocusedElementIdentity(processID: 42, bundleID: "test.host", identifier: "field")
        return ReplacementRequest(
            transaction: ConversionTransaction(
                original: "ghbdtn",
                replacement: "привет",
                boundary: .space(count: 1),
                focus: focus,
                sourceLayoutID: "en",
                targetLayoutID: "ru",
                sequence: 7,
                editRevision: 3,
                expectedOriginalSuffix: "ghbdtn",
                automatic: true
            ),
            deliveredKeyCount: 6,
            currentFocus: focus,
            currentRevision: currentRevision,
            allowUnavailablePost: allowUnavailablePost
        )
    }
}

private final class Reader: FocusedTextContextReading {
    let preflight: TextContextValidation
    var focusOverride: FocusedElementIdentity?
    private(set) var validationDeadlines: [Int] = []
    private(set) var verificationDeadlines: [Int] = []
    private var completion: (@MainActor (TextContextValidation) -> Void)?

    init(preflight: TextContextValidation) { self.preflight = preflight }

    func validate(expectedSuffix: String, focus: FocusedElementIdentity, deadlineMilliseconds: Int) -> TextContextPreflight {
        validationDeadlines.append(deadlineMilliseconds)
        switch preflight {
        case .match:
            return TextReplacementAnchor.capture(expectedSuffix: expectedSuffix, focus: focusOverride ?? focus,
                selection: NSRange(location: expectedSuffix.utf16.count, length: 0),
                capturedRange: NSRange(location: 0, length: expectedSuffix.utf16.count), capturedText: expectedSuffix)
        case .mismatch: return .mismatch
        case .unavailable: return .unavailable
        }
    }

    func verify(expectedSuffix: String, anchor: TextReplacementAnchor, deadlineMilliseconds: Int, completion: @escaping @MainActor (TextContextValidation) -> Void) {
        verificationDeadlines.append(deadlineMilliseconds)
        self.completion = completion
    }

    @MainActor func complete(_ result: TextContextValidation) { completion?(result) }
}

@MainActor
private final class Poster: KeyboardEventPosting {
    let result: Bool
    var plans: [EventReplacementPlan] = []
    var deliveries: [KeyboardEventDelivery] = []

    init(result: Bool) { self.result = result }

    func post(
        _ plan: EventReplacementPlan,
        to processID: Int32,
        delivery: KeyboardEventDelivery
    ) -> Bool {
        plans.append(plan)
        deliveries.append(delivery)
        return result
    }
}
