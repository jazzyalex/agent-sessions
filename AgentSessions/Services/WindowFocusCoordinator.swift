import Foundation
import Combine

/// Window-level focus coordinator for mutually exclusive search UI states.
/// Matches Apple Notes architecture where Find and Search are window-scoped, not global.
/// Uses action-based API with transition guards to prevent invalid states.
final class WindowFocusCoordinator: ObservableObject {
    enum FocusTarget: Equatable {
        case sessionsList    // Sessions list has focus (arrow keys navigate)
        case sessionSearch   // Search sessions list (Cmd+Option+F)
        case transcriptFind  // Find in transcript (Cmd+F)
        case none
    }

    enum FocusAction {
        case openSessionSearch
        case openTranscriptFind
        case selectSession(id: String)
        case closeAllSearch
        case focusSessionsList
    }

    @Published private(set) var activeFocus: FocusTarget = .none
    @Published private(set) var currentSessionID: String? = nil

    /// Perform a focus action with enforced transition guards
    func perform(_ action: FocusAction) {
        #if DEBUG
        let oldFocus = activeFocus
        #endif

        switch action {
        case .openSessionSearch:
            transitionTo(.sessionSearch)

        case .openTranscriptFind:
            transitionTo(.transcriptFind)

        case .selectSession(let id):
            // GUARD: Selecting a new session FORCES cleanup of all search UI
            currentSessionID = id
            transitionTo(.none)

        case .closeAllSearch:
            transitionTo(.none)

        case .focusSessionsList:
            transitionTo(.sessionsList)
        }

        #if DEBUG
        if oldFocus != activeFocus {
            print("🎯 FOCUS: \(oldFocus) → \(activeFocus) (action: \(action))")
        }
        #endif
    }

    /// Internal transition with mutual exclusion enforcement
    private func transitionTo(_ newFocus: FocusTarget) {
        // Guard: Prevent no-op transitions
        guard activeFocus != newFocus else { return }

        // Guard: Only one search UI can be active at a time
        if newFocus == .sessionSearch || newFocus == .transcriptFind {
            // Implicitly closes other search UI
        }

        activeFocus = newFocus
    }

    /// Legacy API for compatibility (deprecated)
    @available(*, deprecated, message: "Use perform(_:) instead")
    func requestFocus(_ target: FocusTarget) {
        switch target {
        case .sessionSearch:
            perform(.openSessionSearch)
        case .transcriptFind:
            perform(.openTranscriptFind)
        case .sessionsList:
            perform(.focusSessionsList)
        case .none:
            perform(.closeAllSearch)
        }
    }

    /// Legacy API for compatibility (deprecated)
    @available(*, deprecated, message: "Use perform(.closeAllSearch) instead")
    func clearFocus() {
        perform(.closeAllSearch)
    }
}
