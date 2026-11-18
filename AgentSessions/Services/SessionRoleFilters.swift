import Foundation

/// Role-chip rules for the Session view. Tools is an independent switch; the
/// other three roles keep the focus-then-restore behavior.
enum SessionRoleFilters {
    static let defaultRaw = "user,assistant,errors"
    static let migrationKey = "SessionRoleFiltersToolsHiddenMigrated"
    private static let storageKey = "SessionRoleFilters"
    private static let base: Set<TranscriptRoleFilter> = [.user, .assistant, .errors]

    static func toggled(_ active: Set<TranscriptRoleFilter>, role: TranscriptRoleFilter) -> Set<TranscriptRoleFilter> {
        var result = active
        if role == .tools {
            if result.contains(.tools) { result.remove(.tools) } else { result.insert(.tools) }
            return result
        }
        let tools = active.contains(.tools)
        var core = active.subtracting([.tools])
        if core == base {
            core = [role]
        } else if core == [role] {
            core = base
        } else if core.contains(role) {
            core.remove(role)
            // An empty set renders a blank pane with no obvious way back.
            if core.isEmpty { core = base }
        } else {
            core.insert(role)
        }
        if tools { core.insert(.tools) }
        return core
    }

    /// The Errors ▲▼ stops that show: failed tool calls follow the Tools chip, so with Tools off
    /// only the standalone `.error` blocks remain.
    static func shownErrorStops(_ errorJumpIDs: [Int], failedInvocationIDs: Set<Int>,
                                activeRoles: Set<TranscriptRoleFilter>) -> [Int] {
        guard !TranscriptToolRows.showsInvocations(activeRoles: activeRoles) else { return errorJumpIDs }
        return errorJumpIDs.filter { !failedInvocationIDs.contains($0) }
    }

    static func parsed(_ raw: String) -> Set<TranscriptRoleFilter> {
        Set(raw.split(separator: ",").compactMap { TranscriptRoleFilter(rawValue: String($0)) })
    }

    /// The shown roles, and whether Find (not the user) turned Tools on.
    struct State: Equatable {
        var active: Set<TranscriptRoleFilter>
        var toolsShownByFind = false
    }

    enum Event: Equatable {
        case chipClicked(TranscriptRoleFilter)
        /// An explicit Find step landed on a row only Tools hides.
        case findRequestedTools
        case sessionChanged
    }

    /// The next state, and whether its `active` set must be saved. Tools that Find turned on is
    /// never saved: it lasts until the session changes or a chip is clicked. Only chip clicks save.
    static func reduce(_ state: State, _ event: Event) -> (state: State, persist: Bool) {
        var next = state
        switch event {
        case .chipClicked(let role):
            // A Tools click acts on the Tools the reader sees; any other chip ends Find's Tools first.
            if state.toolsShownByFind && role != .tools { next.active.remove(.tools) }
            next.active = toggled(next.active, role: role)
            next.toolsShownByFind = false
            return (next, true)
        case .findRequestedTools:
            // An empty set shows every role.
            guard !state.active.isEmpty, !state.active.contains(.tools) else { return (state, false) }
            next.active.insert(.tools)
            next.toolsShownByFind = true
            return (next, false)
        case .sessionChanged:
            guard state.toolsShownByFind else { return (state, false) }
            next.active.remove(.tools)
            next.toolsShownByFind = false
            return (next, false)
        }
    }

    static func migratedRaw(_ raw: String) -> String {
        let kept = raw.split(separator: ",").filter { $0 != "tools" }
        return kept.isEmpty ? defaultRaw : kept.joined(separator: ",")
    }

    static func migrateIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        if let raw = defaults.string(forKey: storageKey) {
            defaults.set(migratedRaw(raw), forKey: storageKey)
        }
        defaults.set(true, forKey: migrationKey)
    }
}
