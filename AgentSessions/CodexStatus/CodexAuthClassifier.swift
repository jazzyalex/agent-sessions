import Foundation

/// Pure, stateful Codex auth classifier — mirror of ClaudeAuthClassifier.
/// Debounces the `signedOut` verdict (>=2 genuine absences >=60s apart) and
/// gates the alarming `.cliNotInstalled` on the deterministic binaryPresent
/// check, so a flaky cli-status or transient fetch never false-alarms.
final class CodexAuthClassifier {
    private var firstMissAt: Date?
    private static let debounce: TimeInterval = 60

    func classify(cliStatus: CLIAuthStatus, creds: CodexCredentialRead,
                  lastFetch: CodexUsageFetchResult?, binaryPresent: Bool, now: Date) -> UsageAuthState {
        let hasToken: Bool = { if case .present = creds { return true } else { return false } }()

        // Verified 401 with a token present ⇒ expired (regardless of CLI status).
        if hasToken, case .unauthorized? = lastFetch { firstMissAt = nil; return .expired }

        // A successful fetch proves the account works even if the creds file was
        // just removed (the fetcher may still be serving a cached token).
        if case .ok? = lastFetch { firstMissAt = nil; return .ok }

        // Deterministic: binary genuinely absent AND no token anywhere → not installed.
        if !binaryPresent && !hasToken { firstMissAt = nil; return .cliNotInstalled }

        // Authoritative CLI status — only .signedIn is a definite verdict here.
        switch cliStatus {
        case .signedIn:
            firstMissAt = nil
            return .ok
        case .cliMissing, .unknown, .signedOut:
            break   // ambiguous/flaky → rely on token evidence + debounce below
        }

        // Token evidence.
        switch creds {
        case .present:
            firstMissAt = nil
            return .ok
        case .malformed:
            return .unknown            // don't alarm on garbage
        case .absent:
            guard let first = firstMissAt else { firstMissAt = now; return .unknown }
            return now.timeIntervalSince(first) >= Self.debounce ? .signedOut : .unknown
        }
    }
}
