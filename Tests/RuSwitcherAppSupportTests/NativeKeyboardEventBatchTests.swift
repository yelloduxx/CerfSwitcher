import CoreGraphics
import XCTest
import RuSwitcherCore
import RuSwitcherAppSupport

final class NativeKeyboardEventBatchTests: XCTestCase {
    private let marker: Int64 = 0x525354455354

    func testBuildsDeletionUnicodeAndEveryBoundaryInOrderWithoutPosting() throws {
        let plan = EventReplacementPlan(backspaceCount: 2, replacementText: "готово", replayText: " \n\t")
        let events = try XCTUnwrap(NativeKeyboardEventBatch.build(plan, marker: marker))
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [51, 51, 51, 51, 0, 0, 49, 49, 36, 36, 48, 48])
        XCTAssertEqual(events.map(\.type), (0..<6).flatMap { _ in [CGEventType.keyDown, .keyUp] })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == marker })
        XCTAssertEqual(unicode(events[4]), "готово")
        XCTAssertNotEqual(unicode(events[5]), plan.replacementText)
        XCTAssertEqual(events.filter { $0.type == .keyDown && unicode($0) == plan.replacementText }.count, 1)
    }

    func testFailureAllocatingTheLastBoundaryEventRejectsTheEntireBatch() {
        var allocations = 0
        let plan = EventReplacementPlan(backspaceCount: 2, replacementText: "готово", replayText: " ")
        let events = NativeKeyboardEventBatch.build(plan, marker: marker, makeEvent: { source, key, down in
            allocations += 1
            if key == 49, !down { return nil }
            return CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        })
        XCTAssertNil(events)
        XCTAssertEqual(allocations, 8, "The failure is after all replacement events have been prepared")
    }

    func testFailureAllocatingBoundarySourceAlsoRejectsTheEntireBatch() {
        var sources = 0
        let plan = EventReplacementPlan(backspaceCount: 2, replacementText: "готово", replayText: " ")
        let events = NativeKeyboardEventBatch.build(plan, marker: marker, makeSource: {
            sources += 1
            return sources == 4 ? nil : CGEventSource(stateID: .hidSystemState)
        })
        XCTAssertNil(events)
        XCTAssertEqual(sources, 4)
    }

    func testInvalidReplayAndEmptyReplacementAreRejectedBeforeAllocation() {
        var sources = 0
        for plan in [EventReplacementPlan(backspaceCount: 2, replacementText: "готово", replayText: "x"),
                     EventReplacementPlan(backspaceCount: 2, replacementText: "", replayText: " ")] {
            XCTAssertNil(NativeKeyboardEventBatch.build(plan, marker: marker, makeSource: {
                sources += 1
                return CGEventSource(stateID: .hidSystemState)
            }))
        }
        XCTAssertEqual(sources, 0)
    }

    func testBackspacePairsKeepIndependentSources() throws {
        var sources: [CGEventSource] = []
        _ = try XCTUnwrap(NativeKeyboardEventBatch.build(
            .init(backspaceCount: 3, replacementText: "done", replayText: " "), marker: marker,
            makeSource: {
                let source = CGEventSource(stateID: .hidSystemState)
                if let source { sources.append(source) }
                return source
            }
        ))
        XCTAssertEqual(sources.count, 5)
        XCTAssertFalse(sources[1] === sources[2])
        XCTAssertFalse(sources[2] === sources[3])
    }

    private func unicode(_ event: CGEvent) -> String {
        var buffer = [UniChar](repeating: 0, count: 128)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
        return String(decoding: buffer.prefix(count), as: UTF16.self)
    }
}
