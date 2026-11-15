import CoreGraphics
import Foundation

struct KeyboardCallbackTiming {
    let eventType: CGEventType
    let keyCode: UInt16
    let marker: Int64
    let startedNanoseconds: UInt64
    let finishedNanoseconds: UInt64
    let consumed: Bool
    let sourceLayoutID: String?
}

/// Probe-only phase marks inside an event callback. Normal runs leave the
/// recorder nil, so marking reads no clock.
enum CallbackPhaseProbe {
    nonisolated(unsafe) static var recorder: ((StaticString, UInt64) -> Void)?

    static func mark(_ phase: StaticString) {
        guard let recorder else { return }
        recorder(phase, DispatchTime.now().uptimeNanoseconds)
    }
}
