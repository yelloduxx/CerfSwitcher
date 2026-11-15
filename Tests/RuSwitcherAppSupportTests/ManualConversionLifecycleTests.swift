import XCTest
@testable import RuSwitcherAppSupport

final class ManualConversionLifecycleTests: XCTestCase {
    func testBusyGestureDoesNotCancelPostedConversion() {
        var feedback = ConversionFeedback()
        var lifecycle = ManualConversionLifecycle()
        let first = feedback.begin(.manual)
        XCTAssertTrue(lifecycle.begin(first))
        let busy = feedback.begin(.manual)
        XCTAssertFalse(lifecycle.begin(busy))
        feedback.record(.refused(.busy), for: busy)
        XCTAssertFalse(lifecycle.finish(busy))
        XCTAssertTrue(lifecycle.isCurrent(first))
        XCTAssertTrue(lifecycle.finish(first))
        XCTAssertFalse(feedback.record(.converted, for: first))
        XCTAssertEqual(feedback.latest?.result, .refused(.busy))
        XCTAssertNil(lifecycle.active)
    }

    func testCancelledCompletionCannotFinishNewOperation() {
        var feedback = ConversionFeedback()
        var lifecycle = ManualConversionLifecycle()
        let cancelled = feedback.begin(.manual)
        XCTAssertTrue(lifecycle.begin(cancelled))
        feedback.record(.refused(.editorChanged), for: cancelled)
        XCTAssertTrue(lifecycle.finish(cancelled))
        let next = feedback.begin(.manual)
        XCTAssertTrue(lifecycle.begin(next))
        XCTAssertFalse(lifecycle.finish(cancelled))
        XCTAssertTrue(lifecycle.isCurrent(next))
    }
}
