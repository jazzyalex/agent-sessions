import Foundation

/// Waits for a window to be observed visible. Completes exactly once;
/// a timeout is a failure, and visibility reported after it is ignored.
public final class VisibilityWait {
    public enum Outcome: Equatable {
        case visible(source: String)
        case timedOut
    }

    private let timeout: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var completion: ((Outcome) -> Void)?

    public init(timeout: TimeInterval = 1.0,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { d, f in
                    DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f)
                }) {
        self.timeout = timeout
        self.schedule = schedule
    }

    public func start(alreadyVisible: Bool, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        if alreadyVisible {
            finish(.visible(source: "initial"))
            return
        }
        schedule(timeout) { [weak self] in self?.finish(.timedOut) }
    }

    public func reportVisible() {
        finish(.visible(source: "occlusion"))
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        completion(outcome)
    }
}
