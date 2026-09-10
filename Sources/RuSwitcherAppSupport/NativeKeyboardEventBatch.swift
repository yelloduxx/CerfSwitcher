import CoreGraphics
import RuSwitcherCore

/// Builds every marked event before publication, including the replay boundary.
/// Allocation failure must never leave a partially posted replacement behind.
public enum NativeKeyboardEventBatch {
    public static func build(
        _ plan: EventReplacementPlan,
        marker: Int64,
        makeSource: () -> CGEventSource? = { CGEventSource(stateID: .hidSystemState) },
        makeEvent: (CGEventSource, CGKeyCode, Bool) -> CGEvent? = {
            CGEvent(keyboardEventSource: $0, virtualKey: $1, keyDown: $2)
        }
    ) -> [CGEvent]? {
        guard !plan.replacementText.isEmpty else { return nil }
        var boundaryKeys: [CGKeyCode] = []
        for character in plan.replayText {
            switch character {
            case " ": boundaryKeys.append(49)
            case "\n": boundaryKeys.append(36)
            case "\t": boundaryKeys.append(48)
            default: return nil
            }
        }
        guard let unicodeSource = makeSource() else { return nil }
        unicodeSource.userData = marker
        unicodeSource.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        var events: [CGEvent] = []
        func pair(source: CGEventSource, key: CGKeyCode) -> (CGEvent, CGEvent)? {
            source.userData = marker
            guard let down = makeEvent(source, key, true), let up = makeEvent(source, key, false) else { return nil }
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            return (down, up)
        }
        for _ in 0..<plan.backspaceCount {
            // Preserve separate sources per Backspace pair for hosts that
            // coalesce repeated key events from a single source.
            guard let source = makeSource(), let (down, up) = pair(source: source, key: 51) else { return nil }
            events.append(contentsOf: [down, up])
        }
        guard let (down, up) = pair(source: unicodeSource, key: 0) else { return nil }
        let utf16 = Array(plan.replacementText.utf16)
        utf16.withUnsafeBufferPointer {
            down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        // Only keyDown gets an explicit replacement payload. Quartz may derive
        // a keyUp string from keycode zero; setting a zero-length payload does
        // not reliably make keyboardGetUnicodeString empty.
        events.append(contentsOf: [down, up])
        for key in boundaryKeys {
            guard let source = makeSource(), let (down, up) = pair(source: source, key: key) else { return nil }
            events.append(contentsOf: [down, up])
        }
        return events
    }
}
