import Foundation

enum AuthProvider: Equatable { case claude, codex
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

enum UsageAuthState: Equatable {
    case ok, signedOut, expired, cliNotInstalled, needsSetup, unknown
    /// States that should raise the loud banner + one-shot notification.
    var isAlarming: Bool {
        switch self { case .signedOut, .expired, .cliNotInstalled: return true
        default: return false }
    }
}

enum Remediation: Equatable {
    case showCommand(String)   // rendered with a Copy button; never auto-run
    case openURL(URL)
    case none
    // Phase 2 adds: case inAppSignIn
}

struct UsageAuthStatus: Equatable {
    var state: UsageAuthState
    var remediation: Remediation
    var headline: String
    var detail: String

    static func make(provider: AuthProvider, state: UsageAuthState) -> UsageAuthStatus {
        let name = provider.displayName
        let loginCmd = provider == .claude ? "claude auth login" : "codex login"
        let installURL = URL(string: provider == .claude
            ? "https://docs.claude.com/en/docs/claude-code/setup"
            : "https://developers.openai.com/codex/cli/")!
        switch state {
        case .ok, .unknown:
            return .init(state: state, remediation: .none, headline: "", detail: "")
        case .signedOut:
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — sign in to \(name)",
                detail: "You're signed out of the \(name) CLI. Run the command below, then runway resumes automatically.")
        case .expired:
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — \(name) session expired",
                detail: "Your \(name) credentials expired. Run the command below to re-authenticate.")
        case .cliNotInstalled:
            return .init(state: state, remediation: .openURL(installURL),
                headline: "Runway needs an account token",
                detail: "Install the \(name) CLI, or (coming soon) sign in to Agent Sessions directly.")
        case .needsSetup:
            return .init(state: state, remediation: .showCommand(provider == .claude ? "claude" : "codex"),
                headline: "\(name) needs one-time setup",
                detail: "Open Terminal and run the \(name) CLI once to finish setup.")
        }
    }
}
