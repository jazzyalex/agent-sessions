import Foundation

// UI-free evidence types for weekly-quota attribution. They live apart from the
// calibration store (CodexStatus/WeeklyQuotaCalibration.swift) because
// `SessionTelemetry` carries a provenance value, and the shared session core, which builds
// without the quota subsystem, needs the type but not the store or scanners.

/// Where the conversion used for an attribution came from. A bootstrap may be
/// from the current quota window or carried across a reset; those are different
/// evidence paths even when they produce the same ratio.
public enum WeeklyQuotaCalibrationOrigin: String, Codable, Sendable {
    case live
    case bootstrap
    case carriedBootstrap
}

/// Evidence for the conversion, kept separate from the latest raw quota poll.
/// The latter says what the provider reported most recently; this says which
/// measurement supplied the pp-per-dollar ratio.
public struct WeeklyQuotaCalibrationProvenance: Equatable, Codable, Sendable {
    public let origin: WeeklyQuotaCalibrationOrigin
    /// Set for a live tracker calibration. Bootstrap scans use `scannedAt`.
    public let acquiredAt: Date?
    /// Set for a bootstrap scan, including a carried-over scan.
    public let scannedAt: Date?
    public let sourceFamily: String
    public let accountHash: String?
    public let priceRevision: Int
    /// Reset/window that the calibration itself was measured against, not the
    /// timestamp of the latest raw quota observation.
    public let originResetAt: Date?
    public let originWindowStart: Date?

    public init(origin: WeeklyQuotaCalibrationOrigin,
                acquiredAt: Date?,
                scannedAt: Date?,
                sourceFamily: String,
                accountHash: String?,
                priceRevision: Int,
                originResetAt: Date?,
                originWindowStart: Date?) {
        self.origin = origin
        self.acquiredAt = acquiredAt
        self.scannedAt = scannedAt
        self.sourceFamily = sourceFamily
        self.accountHash = accountHash
        self.priceRevision = priceRevision
        self.originResetAt = originResetAt
        self.originWindowStart = originWindowStart
    }
}
