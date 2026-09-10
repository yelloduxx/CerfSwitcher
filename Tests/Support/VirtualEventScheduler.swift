import RuSwitcherAppSupport

/// Deterministic test time. Queue order breaks equal-time ties; advancing time
/// never sleeps or dispatches work to the user's desktop event stream.
@MainActor
public final class VirtualEventScheduler: ReplacementCompletionScheduling {
    private struct Event {
        let at: UInt64
        let sequence: UInt64
        let action: @MainActor () -> Void
    }
    public private(set) var now: UInt64 = 0
    private var sequence: UInt64 = 0
    private var events: [Event] = []

    public init() {}

    public func enqueue(_ action: @escaping @MainActor () -> Void) {
        schedule(at: now, action)
    }

    public func schedule(at time: UInt64, _ action: @escaping @MainActor () -> Void) {
        precondition(time >= now, "cannot schedule into the past")
        sequence += 1
        events.append(Event(at: time, sequence: sequence, action: action))
        events.sort { $0.at == $1.at ? $0.sequence < $1.sequence : $0.at < $1.at }
    }

    public func advance(to time: UInt64) {
        precondition(time >= now, "test clock must be monotonic")
        while let event = events.first, event.at <= time {
            events.removeFirst()
            now = event.at
            event.action()
        }
        now = time
    }

    public func drain() {
        while let event = events.first { advance(to: event.at) }
    }
}
