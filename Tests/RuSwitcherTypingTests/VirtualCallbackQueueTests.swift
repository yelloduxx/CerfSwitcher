import XCTest
import RuSwitcherTestSupport

@MainActor
final class VirtualCallbackQueueTests: XCTestCase {
    func testBusyCallbackHoldsInputAndAcknowledgementsButNotExternalDelivery() {
        let clock = VirtualEventScheduler()
        let queue = VirtualCallbackQueue(clock: clock)
        var trace: [String] = []
        queue.perform { done in
            trace.append("callback-start")
            clock.schedule(at: 20) { trace.append("callback-end"); done() }
        }
        clock.schedule(at: 5) { trace.append("input-arrived"); queue.enqueue { trace.append("input-processed") } }
        clock.schedule(at: 7) { trace.append("editor-delivery") }
        clock.schedule(at: 8) { queue.enqueue { trace.append("acknowledgement") } }
        clock.advance(to: 19)
        XCTAssertEqual(trace, ["callback-start", "input-arrived", "editor-delivery"])
        clock.drain()
        XCTAssertEqual(trace, ["callback-start", "input-arrived", "editor-delivery", "callback-end", "input-processed", "acknowledgement"])
    }

    func testCompletionIsAlwaysDeferredAndDuplicateReleaseCannotRunConcurrentWork() {
        let clock = VirtualEventScheduler()
        let queue = VirtualCallbackQueue(clock: clock)
        var trace: [Int] = []
        queue.enqueue { trace.append(1) }
        XCTAssertEqual(trace, [])
        queue.perform { done in
            trace.append(2)
            clock.schedule(at: 10) { done(); done() }
        }
        queue.perform { done in
            trace.append(3)
            clock.schedule(at: 20) { trace.append(4); done() }
        }
        queue.enqueue { trace.append(5) }
        clock.advance(to: 19)
        XCTAssertEqual(trace, [1, 2, 3])
        clock.drain()
        XCTAssertEqual(trace, [1, 2, 3, 4, 5])
    }
}
