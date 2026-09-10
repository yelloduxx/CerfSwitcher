import RuSwitcherAppSupport

/// The app's serial callback lane, separate from input arrival and editor
/// delivery. Work may retain its completion while virtual time keeps advancing.
@MainActor
public final class VirtualCallbackQueue: ReplacementCompletionScheduling {
    private typealias Work = (@escaping @MainActor () -> Void) -> Void
    private let clock: VirtualEventScheduler
    private var pending: [Work] = []
    private var active = false
    private var scheduled = false

    public init(clock: VirtualEventScheduler) { self.clock = clock }

    public var isIdle: Bool { !active && !scheduled && pending.isEmpty }

    public func enqueue(_ action: @escaping @MainActor () -> Void) {
        perform { done in action(); done() }
    }

    public func perform(_ action: @escaping (@escaping @MainActor () -> Void) -> Void) {
        pending.append(action)
        scheduleNext()
    }

    private func scheduleNext() {
        guard !active, !scheduled, !pending.isEmpty else { return }
        scheduled = true
        clock.enqueue { [self] in
            scheduled = false
            guard !active, !pending.isEmpty else { return }
            active = true
            let work = pending.removeFirst()
            var released = false
            work { [self] in
                guard !released else { return }
                released = true
                active = false
                scheduleNext()
            }
        }
    }
}
