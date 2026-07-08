import Foundation

enum CLIAuthStatus: Equatable { case signedIn, signedOut, cliMissing, unknown }

struct ClaudeAuthInputs {
    var cliStatus: CLIAuthStatus
    var keychain: KeychainRead
    var credsFilePresentToken: Bool
    var binaryPresent: Bool
    /// True when `CLAUDE_CODE_OAUTH_TOKEN` is set in the environment. This is the
    /// token resolver's source #1, so an env-token user is authenticated even with
    /// no keychain/creds-file token — treated as token evidence in `hasToken`.
    var envTokenPresent: Bool = false
}

/// Pure, stateful classifier. Debounces the `signedOut` verdict so a transient
/// or unreadable read never false-alarms (spec: ≥2 "absent" resolutions ≥60s apart).
final class ClaudeAuthClassifier {
    private var firstMissAt: Date?
    private static let debounce: TimeInterval = 60

    func classify(_ i: ClaudeAuthInputs, now: Date) -> UsageAuthState {
        let hasToken = i.credsFilePresentToken || i.keychain.isFound || i.envTokenPresent

        // Deterministic: the binary is genuinely absent on disk AND no token exists
        // anywhere. Driven by binaryPresent (a disk check), so it needs no debounce.
        if !i.binaryPresent && !hasToken {
            firstMissAt = nil
            return .cliNotInstalled
        }

        // Authoritative CLI status — only .signedIn is a definite verdict here.
        switch i.cliStatus {
        case .signedIn:
            firstMissAt = nil
            return .ok
        case .cliMissing, .unknown, .signedOut:
            break   // ambiguous/flaky → rely on token evidence + debounce below
        }

        // An env-provided OAuth token (CLAUDE_CODE_OAUTH_TOKEN) is authoritative
        // token evidence on its own — the resolver's source #1. A working-runway
        // user with only an env token must never be misread as tokenless and
        // debounced toward .signedOut. Clears the timer and resolves via expiry.
        if i.envTokenPresent {
            firstMissAt = nil
            return tokenExpiryState(i)
        }

        // Token evidence.
        switch i.keychain {
        case .found:
            firstMissAt = nil
            return tokenExpiryState(i)
        case .unreadable:
            // A confirmed-good creds-file token clears the debounce timer; an
            // unreadable keychain with no token is neutral (never alarms, never resets).
            if i.credsFilePresentToken {
                firstMissAt = nil
                return tokenExpiryState(i)
            }
            return .unknown
        case .notFound:
            if i.credsFilePresentToken {
                firstMissAt = nil
                return tokenExpiryState(i)
            }
        }

        // Genuinely absent — debounce before alarming (≥2 misses ≥60s apart).
        guard let first = firstMissAt else {
            firstMissAt = now
            return .unknown
        }
        return now.timeIntervalSince(first) >= Self.debounce ? .signedOut : .unknown
    }

    /// Clears the debounce clock. Call this when a non-absent verdict is reached
    /// OUTSIDE `classify()` (e.g. the OAuth success `.ok` fast-path, or the
    /// token-present `.expired` fast-path). Two isolated transient misses with a
    /// healthy poll between them must not accumulate into a false `.signedOut`
    /// just because those healthy polls skipped `classify()`.
    func reset() { firstMissAt = nil }

    /// Token is present; only a verified 401 elsewhere flips this to `.expired`.
    /// Here we default to `.ok`; the source manager overrides with `.expired` on 401.
    private func tokenExpiryState(_ i: ClaudeAuthInputs) -> UsageAuthState { .ok }
}

private extension KeychainRead {
    var isFound: Bool {
        if case .found = self { return true }
        return false
    }
}
