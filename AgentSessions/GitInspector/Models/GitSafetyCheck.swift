import Foundation

/// Result of comparing historical git context with current git status
/// Provides safety recommendations for resuming a session
public struct GitSafetyCheck: Equatable {
    public let status: SafetyStatus
    public let checks: [CheckResult]
    public let recommendation: String

    public init(status: SafetyStatus, checks: [CheckResult], recommendation: String) {
        self.status = status
        self.checks = checks
        self.recommendation = recommendation
    }

    /// Overall safety status
    public enum SafetyStatus: String, Equatable {
        case safe       // Same branch, no changes - completely safe
        case caution    // Same branch, but uncommitted changes present
        case warning    // Different branch or new commits - potentially dangerous
        case unknown    // Can't determine (missing data)

        /// Icon for this status
        public var icon: String {
            switch self {
            case .safe: return "checkmark.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .unknown: return "questionmark.circle.fill"
            }
        }

        /// Color for this status
        public var color: String {
            switch self {
            case .safe: return "green"
            case .caution: return "orange"
            case .warning: return "red"
            case .unknown: return "gray"
            }
        }

        /// Title for this status
        public var title: String {
            switch self {
            case .safe: return "SAFE"
            case .caution: return "CAUTION"
            case .warning: return "WARNING"
            case .unknown: return "UNKNOWN"
            }
        }
    }

    /// Individual safety check result
    public struct CheckResult: Equatable, Identifiable {
        public let id: String
        public let icon: String
        public let message: String
        public let passed: Bool

        public init(icon: String, message: String, passed: Bool) {
            self.id = message
            self.icon = icon
            self.message = message
            self.passed = passed
        }
    }

    /// Whether it's safe to resume without warnings
    public var isSafeToResume: Bool {
        status == .safe
    }

    /// Whether user should be warned before resuming
    public var shouldWarnBeforeResume: Bool {
        status == .caution || status == .warning
    }

    /// Number of failed checks
    public var failedCheckCount: Int {
        checks.filter { !$0.passed }.count
    }
}
