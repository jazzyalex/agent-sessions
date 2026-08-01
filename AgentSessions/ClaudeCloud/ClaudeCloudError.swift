import Foundation

/// Failure vocabulary for the Claude cloud-session source.
///
/// Every case here has a distinct rendered surface in `ClaudeCloudSourceState`.
/// That pairing is deliberate: a degraded state that is computed but never drawn
/// is what turns a recoverable failure into an apparent hang.
enum ClaudeCloudError: Error, Equatable {
    /// No claude.ai session cookie stored — nothing was requested.
    case notConnected
    /// 401: the stored cookie is no longer valid.
    case expired
    /// 429. `until` is parsed from `Retry-After` when the server supplies it.
    case rateLimited(until: Date?)
    /// Transport failure (offline, DNS, timeout).
    case offline
    /// 2xx that did not decode, or a non-2xx we have no specific mapping for.
    /// These endpoints are undocumented, so drift is expected rather than exceptional.
    case contractDrift(String)
}
