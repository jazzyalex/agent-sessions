import Foundation

struct CrashReportEnvelope: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let detectedAt: Date
    let reportSourcePathHash: String
    let reportFilename: String
    let crashTimestamp: Date?
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let architecture: String
    let terminationSummary: String
    let topFrames: [String]
    // Uncaught-exception detail from the .ips `asi` and `lastExceptionBacktrace`.
    // Optional so pending reports saved by older builds still decode.
    let exceptionReason: String?
    let exceptionBacktrace: [String]?
    let breadcrumbs: [String]
    let rawMetadata: [String: String]

    var eventTitle: String {
        if terminationSummary.isEmpty { return "Crash Detected" }
        return terminationSummary
    }

    func redactedForUpload() -> CrashReportEnvelope {
        CrashReportEnvelope(
            id: id,
            detectedAt: detectedAt,
            reportSourcePathHash: reportSourcePathHash,
            reportFilename: reportFilename,
            crashTimestamp: crashTimestamp,
            appVersion: appVersion,
            appBuild: appBuild,
            macOSVersion: macOSVersion,
            architecture: architecture,
            terminationSummary: CrashReportSanitizer.truncate(terminationSummary, limit: 400),
            topFrames: topFrames.prefix(10).map { CrashReportSanitizer.sanitizeFrame($0) },
            exceptionReason: exceptionReason.map { CrashReportSanitizer.sanitizeText($0, limit: CrashReportSanitizer.exceptionReasonLimit) },
            exceptionBacktrace: exceptionBacktrace.map { frames in
                frames.prefix(CrashReportSanitizer.exceptionBacktraceLimit).map { CrashReportSanitizer.sanitizeFrame($0) }
            },
            breadcrumbs: breadcrumbs.prefix(20).map { CrashReportSanitizer.truncate($0, limit: 180) },
            rawMetadata: rawMetadata.reduce(into: [:]) { partial, entry in
                partial[entry.key] = CrashReportSanitizer.truncate(entry.value, limit: 220)
            }
        )
    }
}

enum CrashReportSanitizer {
    static let exceptionReasonLimit = 1000
    static let exceptionBacktraceLimit = 30

    static func sanitizeFrame(_ frame: String) -> String {
        let trimmed = frame.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "<unknown frame>" }
        return sanitizeText(trimmed, limit: 240)
    }

    /// Replaces path-like tokens with `<path>` so user folder names do not leave the Mac.
    static func sanitizeText(_ text: String, limit: Int) -> String {
        let components = text.split(whereSeparator: \.isWhitespace)
        let cleaned = components.map { token -> String in
            let value = String(token)
            if value.hasPrefix("/") || value.contains("/Users/") || value.contains("/private/") || value.contains("/var/") {
                return "<path>"
            }
            return value
        }
        return truncate(cleaned.joined(separator: " "), limit: limit)
    }

    static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "…"
    }
}
