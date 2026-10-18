import Foundation

/// Hover open/close dwell across several separate panels. Only the
/// empty <-> non-empty transitions of the active-region set act.
public struct HoverDwell {
    public enum Action: Equatable {
        case none, scheduleOpen(TimeInterval), scheduleClose(TimeInterval), cancelTimers
    }

    public private(set) var isOpen = false
    public private(set) var activeRegions: Set<String> = []
    private let openDelay: TimeInterval
    private let closeDelay: TimeInterval
    private var pending: Action = .none

    public init(openDelay: TimeInterval = 0.35, closeDelay: TimeInterval = 0.7) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    public mutating func pointer(entered region: String) -> Action {
        let wasEmpty = activeRegions.isEmpty
        activeRegions.insert(region)
        guard wasEmpty else { return .none }
        return set(isOpen ? .cancelTimers : .scheduleOpen(openDelay))
    }

    public mutating func pointer(exited region: String) -> Action {
        guard activeRegions.remove(region) != nil, activeRegions.isEmpty else { return .none }
        return set(isOpen ? .scheduleClose(closeDelay) : .cancelTimers)
    }

    /// Returns true when the panel should toggle.
    public mutating func timerFired() -> Bool {
        defer { pending = .none }
        switch pending {
        case .scheduleOpen: isOpen = true; return true
        case .scheduleClose: isOpen = false; return true
        case .none, .cancelTimers: return false
        }
    }

    private mutating func set(_ action: Action) -> Action {
        pending = action
        return action
    }
}
