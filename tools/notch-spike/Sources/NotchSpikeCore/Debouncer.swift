import Foundation

/// Runs only the last action called within `delay`.
public final class Debouncer {
    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0

    public init(delay: TimeInterval,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { d, f in
                    DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f)
                }) {
        self.delay = delay
        self.schedule = schedule
    }

    public func call(_ action: @escaping () -> Void) {
        generation += 1
        let mine = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == mine else { return }
            action()
        }
    }
}
