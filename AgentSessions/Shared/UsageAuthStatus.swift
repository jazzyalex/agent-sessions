import Foundation

enum AuthProvider: Equatable { case claude, codex
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

enum UsageAuthState: Equatable {
    case ok, signedOut, expired, cliNotInstalled, needsSetup, unknown
    /// Signed in, but the saved access token lapsed from inactivity (nothing
    /// refreshes it between sessions — only a real Claude session does). The
    /// account is fine and usage resumes on the next session, so this is calm
    /// by design: no banner, no notification, no "Fix…" chip.
    case idle
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
    /// Provider display name ("Claude"/"Codex"), retained so compact surfaces
    /// (footer chip, menu-bar face) can build a short label without the full
    /// "Runway paused — …" headline.
    var providerName: String = ""

    /// Ultra-short label for the compact footer chip. Drops the "Runway paused —"
    /// preamble the full-banner headline carries, so the chip stays a single tight
    /// pill. Empty for non-alarming states.
    var chipLabel: String {
        let name = providerName.isEmpty ? "CLI" : providerName
        switch state {
        case .signedOut: return "\(name) signed out"
        case .expired: return "\(name) auth expired"
        case .cliNotInstalled: return "\(name) token needed"
        case .needsSetup: return "\(name) needs setup"
        // Idle renders via the dedicated calm cells (footer / HUD / menu bar),
        // never the alarming chip.
        case .ok, .unknown, .idle: return ""
        }
    }

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
            return .init(state: state, remediation: .none, headline: "", detail: "", providerName: name)
        case .idle:
            // Honest, non-alarming: the account is signed in; the token just
            // lapsed from inactivity. Since the latch fix, this cell renders only
            // while NO source is serving data, so the Claude detail carries the
            // recovery ladder instead of a passive "wait": (1) any terminal
            // `claude` run refreshes the CLI token — desktop-app sessions never
            // do; (2) a pasted claude.ai cookie feeds the web path; (3) the
            // double-click CLI probe is the last resort (needs the CLI installed
            // and can consume tokens, so it is never auto-run).
            if provider == .claude {
                return .init(state: state, remediation: .none,
                    headline: "No active \(name) session",
                    detail: "Usage paused — the saved CLI token lapsed. Run any claude command in Terminal to refresh it, or paste a claude.ai session cookie in Settings. Last resort: double-click the meter for a CLI probe (may consume tokens).",
                    providerName: name)
            }
            return .init(state: state, remediation: .none,
                headline: "No active \(name) session",
                detail: "Usage will update after the next \(name) session.",
                providerName: name)
        case .signedOut:
            if claudeNoCLI {
                return .init(state: state, remediation: ladder,
                    headline: "Runway paused — sign in to \(name)", detail: ladderDetail, providerName: name)
            }
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — sign in to \(name)",
                detail: "You're signed out of the \(name) CLI. Run the command below, then runway resumes automatically.",
                providerName: name)
        case .expired:
            if claudeNoCLI {
                return .init(state: state, remediation: ladder,
                    headline: "Runway paused — \(name) session expired", detail: ladderDetail, providerName: name)
            }
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — \(name) session expired",
                detail: "Your \(name) credentials expired. Run the command below to re-authenticate.",
                providerName: name)
        case .cliNotInstalled:
            // CLI-less by definition. Claude → the ladder (drops the cancelled
            // in-app-sign-in promise the old copy carried); Codex → its install
            // link (no Web API rung exists for Codex).
            if provider == .claude {
                return .init(state: state, remediation: ladder,
                    headline: "Runway needs an account token", detail: ladderDetail, providerName: name)
            }
            return .init(state: state, remediation: .openURL(installURL),
                headline: "Runway needs an account token",
                detail: "Install the \(name) CLI to read usage.",
                providerName: name)
        case .needsSetup:
            return .init(state: state, remediation: .showCommand(provider == .claude ? "claude" : "codex"),
                headline: "\(name) needs one-time setup",
                detail: "Open Terminal and run the \(name) CLI once to finish setup.",
                providerName: name)
        }
    }
}
