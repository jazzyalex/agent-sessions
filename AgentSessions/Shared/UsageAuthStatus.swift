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
    /// No-CLI ladder (Claude, CLI-less users): rung 1 = enable the already-shipped
    /// Web API mode (no install), rung 2 = install the CLI. Rendered as a
    /// "How to fix…" alert. AS never mints a token or runs an installer. (spec §5)
    case noCLILadder(installCommand: String, docsURL: URL)
    case none
}

struct UsageAuthStatus: Equatable {
    var state: UsageAuthState
    var remediation: Remediation
    var headline: String
    var detail: String

    /// - Parameter cliPresent: whether the provider's CLI is installed. When it
    ///   is absent (CLI-less Claude users), alarming states offer the no-CLI
    ///   ladder (rung 1 = Web API mode, rung 2 = guided CLI install) instead of a
    ///   copy-command they can't run. Defaults to `true` so every existing call
    ///   site and the Codex path are unchanged.
    static func make(provider: AuthProvider, state: UsageAuthState, cliPresent: Bool = true) -> UsageAuthStatus {
        let name = provider.displayName
        let loginCmd = provider == .claude ? "claude auth login" : "codex login"
        let installURL = URL(string: provider == .claude
            ? "https://docs.claude.com/en/docs/claude-code/setup"
            : "https://developers.openai.com/codex/cli/")!
        // Claude-only no-CLI ladder (rung 1 Web API mode, rung 2 guided install).
        // Web API mode is a Claude-specific shipped path, so Codex never ladders.
        let claudeInstallCmd = "npm install -g @anthropic-ai/claude-code"
        let ladderDetail = "Sign in at claude.ai, then enable Web API mode — or install the Claude CLI so Agent Sessions can read usage directly."
        let ladder = Remediation.noCLILadder(installCommand: claudeInstallCmd, docsURL: installURL)
        let claudeNoCLI = (provider == .claude && !cliPresent)

        switch state {
        case .ok, .unknown:
            return .init(state: state, remediation: .none, headline: "", detail: "")
        case .signedOut:
            if claudeNoCLI {
                return .init(state: state, remediation: ladder,
                    headline: "Runway paused — sign in to \(name)", detail: ladderDetail)
            }
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — sign in to \(name)",
                detail: "You're signed out of the \(name) CLI. Run the command below, then runway resumes automatically.")
        case .expired:
            if claudeNoCLI {
                return .init(state: state, remediation: ladder,
                    headline: "Runway paused — \(name) session expired", detail: ladderDetail)
            }
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — \(name) session expired",
                detail: "Your \(name) credentials expired. Run the command below to re-authenticate.")
        case .cliNotInstalled:
            // CLI-less by definition. Claude → the ladder (drops the cancelled
            // in-app-sign-in promise the old copy carried); Codex → its install
            // link (no Web API rung exists for Codex).
            if provider == .claude {
                return .init(state: state, remediation: ladder,
                    headline: "Runway needs an account token", detail: ladderDetail)
            }
            return .init(state: state, remediation: .openURL(installURL),
                headline: "Runway needs an account token",
                detail: "Install the \(name) CLI to read usage.")
        case .needsSetup:
            return .init(state: state, remediation: .showCommand(provider == .claude ? "claude" : "codex"),
                headline: "\(name) needs one-time setup",
                detail: "Open Terminal and run the \(name) CLI once to finish setup.")
        }
    }
}
