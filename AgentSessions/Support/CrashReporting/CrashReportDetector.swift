import Foundation
import Darwin

struct CrashReportDetector {
    private let fileManager: FileManager
    private let reportsRootURL: URL
    private let appName: String
    private let bundleIdentifier: String
    private let appVersion: String
    private let appBuild: String
    private let nowProvider: () -> Date
    private let lookbackWindow: TimeInterval
    private let maxReports: Int

    init(fileManager: FileManager = .default,
         reportsRootURL: URL? = nil,
         appName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Agent Sessions",
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.triada.AgentSessions",
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
         appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         nowProvider: @escaping () -> Date = Date.init,
         lookbackWindow: TimeInterval = 14 * 24 * 60 * 60,
         maxReports: Int = 20) {
        self.fileManager = fileManager
        if let reportsRootURL {
            self.reportsRootURL = reportsRootURL
        } else {
            self.reportsRootURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        }
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.nowProvider = nowProvider
        self.lookbackWindow = lookbackWindow
        self.maxReports = maxReports
    }

    func detectRecentCrashes() -> [CrashReportEnvelope] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: reportsRootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: reportsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let cutoff = nowProvider().addingTimeInterval(-lookbackWindow)

        let candidates = files
            .filter { ["ips", "crash"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                let mtime = values?.contentModificationDate ?? .distantPast
                guard mtime >= cutoff else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }

        var detected: [CrashReportEnvelope] = []
        detected.reserveCapacity(maxReports)

        for (url, modifiedAt) in candidates {
            guard let envelope = makeEnvelope(from: url, fallbackDetectedAt: modifiedAt) else { continue }
            detected.append(envelope)
            if detected.count >= maxReports { break }
        }

        return detected.sorted { $0.detectedAt > $1.detectedAt }
    }

    private func makeEnvelope(from url: URL, fallbackDetectedAt: Date) -> CrashReportEnvelope? {
        guard let rawData = try? Data(contentsOf: url),
              let text = String(data: rawData, encoding: .utf8) else {
            return nil
        }

        let parsed: ParsedCrash?
        switch url.pathExtension.lowercased() {
        case "ips":
            parsed = parseIPS(text: text)
        case "crash":
            parsed = parseCrashText(text)
        default:
            parsed = nil
        }

        guard let parsed else { return nil }

        let metadata = parsed.metadata.reduce(into: [String: String]()) { partial, entry in
            partial[entry.key] = CrashReportSanitizer.truncate(entry.value, limit: 220)
        }

        let topFrames = parsed.topFrames.prefix(10).map { CrashReportSanitizer.sanitizeFrame($0) }
        let breadcrumbs = [
            "launch.diagnostics_scan",
            "source:\(url.lastPathComponent)",
            "detected:\(AppDateFormatting.dateTimeMedium(fallbackDetectedAt))"
        ]

        let sourceHash = stableHash(url.path)
        let crashTime = parsed.crashTimestamp
        let idSeed = "\(sourceHash)|\(crashTime?.timeIntervalSince1970 ?? 0)|\(parsed.terminationSummary)|\(topFrames.first ?? "")"

        return CrashReportEnvelope(
            id: stableHash(idSeed),
            detectedAt: fallbackDetectedAt,
            reportSourcePathHash: sourceHash,
            reportFilename: url.lastPathComponent,
            crashTimestamp: crashTime,
            appVersion: parsed.appVersion ?? appVersion,
            appBuild: parsed.appBuild ?? appBuild,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: machineArchitecture(),
            terminationSummary: CrashReportSanitizer.truncate(parsed.terminationSummary, limit: 400),
            topFrames: topFrames,
            breadcrumbs: breadcrumbs,
            rawMetadata: metadata
        )
    }

    private func parseCrashText(_ text: String) -> ParsedCrash? {
        let lower = text.lowercased()
        guard lower.contains(bundleIdentifier.lowercased()) ||
                lower.contains("process: \(appName.lowercased())") ||
                lower.contains("identifier: \(bundleIdentifier.lowercased())") else {
            return nil
        }

        let lines = text.components(separatedBy: .newlines)
        let crashTimestamp = parseCrashTimestamp(from: lines)
        let rawVersion = firstValue(after: "Version:", in: lines)
        let parsedVersionBuild = parseVersionAndBuild(from: rawVersion)

        let exceptionType = firstValue(after: "Exception Type:", in: lines)
        let exceptionCodes = firstValue(after: "Exception Codes:", in: lines)
        let terminationReason = firstValue(after: "Termination Reason:", in: lines)

        var summaryParts: [String] = []
        if let exceptionType { summaryParts.append("\(exceptionType)") }
        if let exceptionCodes { summaryParts.append("\(exceptionCodes)") }
        if let terminationReason { summaryParts.append("\(terminationReason)") }
        let summary = summaryParts.isEmpty ? "Crash report from macOS DiagnosticReports" : summaryParts.joined(separator: " | ")

        let topFrames = parseTopFramesFromCrashLines(lines)

        var meta = [
            "format": "crash",
            "exceptionType": exceptionType ?? "",
            "terminationReason": terminationReason ?? ""
        ]
        if let appVersion = parsedVersionBuild.version {
            meta["reportAppVersion"] = appVersion
        }
        if let appBuild = parsedVersionBuild.build {
            meta["reportAppBuild"] = appBuild
        }

        return ParsedCrash(crashTimestamp: crashTimestamp,
                           terminationSummary: summary,
                           topFrames: topFrames,
                           metadata: meta,
                           appVersion: parsedVersionBuild.version,
                           appBuild: parsedVersionBuild.build)
    }

    private func parseIPS(text: String) -> ParsedCrash? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return nil }

        var headerJSON: [String: Any]?
        var payloadJSON: [String: Any]?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if headerJSON == nil {
                headerJSON = obj
            } else {
                payloadJSON = obj
                break
            }
        }

        let procName = (headerJSON?["procName"] as? String) ?? ""
        let bundleID = (headerJSON?["bundleID"] as? String) ?? (headerJSON?["bundleIdentifier"] as? String) ?? ""
        let textLower = text.lowercased()
        let appMatch = procName.caseInsensitiveCompare(appName) == .orderedSame
            || bundleID.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            || textLower.contains(bundleIdentifier.lowercased())

        guard appMatch else { return nil }

        let crashTimestamp = parseIPSTimestamp(headerJSON: headerJSON, payloadJSON: payloadJSON)
        let parsedVersionBuild = parseIPSVersionBuild(headerJSON: headerJSON, payloadJSON: payloadJSON)

        var summaryParts: [String] = []
        if let exception = payloadJSON?["exception"] as? [String: Any] {
            if let type = exception["type"] as? String, !type.isEmpty { summaryParts.append(type) }
            if let signal = exception["signal"] as? String, !signal.isEmpty { summaryParts.append(signal) }
        }
        if let termination = payloadJSON?["termination"] as? [String: Any] {
            if let reason = termination["reason"] as? String, !reason.isEmpty { summaryParts.append(reason) }
            if let namespace = termination["namespace"] as? String, !namespace.isEmpty { summaryParts.append("namespace=\(namespace)") }
        }
        if summaryParts.isEmpty {
            summaryParts.append("Crash report from macOS DiagnosticReports")
        }

        let topFrames = parseTopFramesFromIPSPayload(payloadJSON, fallbackText: text)

        var metadata: [String: String] = [:]
        metadata["format"] = "ips"
        metadata["procName"] = procName
        if !bundleID.isEmpty { metadata["bundleID"] = bundleID }
        if let incident = headerJSON?["incident"] as? String { metadata["incident"] = incident }
        if let appVersion = parsedVersionBuild.version { metadata["reportAppVersion"] = appVersion }
        if let appBuild = parsedVersionBuild.build { metadata["reportAppBuild"] = appBuild }

        return ParsedCrash(crashTimestamp: crashTimestamp,
                           terminationSummary: summaryParts.joined(separator: " | "),
                           topFrames: topFrames,
                           metadata: metadata,
                           appVersion: parsedVersionBuild.version,
                           appBuild: parsedVersionBuild.build)
    }

    private func parseTopFramesFromCrashLines(_ lines: [String]) -> [String] {
        guard let crashThreadIndex = lines.firstIndex(where: { $0.contains("Crashed:") && $0.contains("Thread") }) else {
            return []
        }

        var frames: [String] = []
        var index = crashThreadIndex + 1
        while index < lines.count, frames.count < 10 {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { break }
            if line.hasPrefix("Thread") && !line.contains("Crashed") { break }
            if line.first?.isNumber == true {
                frames.append(line)
            }
            index += 1
        }
        return frames
    }

    private func parseTopFramesFromIPSPayload(_ payloadJSON: [String: Any]?, fallbackText: String) -> [String] {
        guard let payloadJSON else {
            return fallbackFrames(from: fallbackText)
        }

        guard let threads = payloadJSON["threads"] as? [[String: Any]], !threads.isEmpty else {
            return fallbackFrames(from: fallbackText)
        }

        let faultingIndex = (payloadJSON["faultingThread"] as? Int) ?? 0
        let thread = threads.indices.contains(faultingIndex) ? threads[faultingIndex] : threads[0]

        guard let frames = thread["frames"] as? [[String: Any]], !frames.isEmpty else {
            return fallbackFrames(from: fallbackText)
        }

        return frames.prefix(10).map { frame in
            let image = (frame["imageName"] as? String) ?? "<image>"
            let symbol = (frame["symbol"] as? String) ?? (frame["symbolLocation"] as? String) ?? "<symbol>"
            return "\(image) \(symbol)"
        }
    }

    private func fallbackFrames(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true }
            .prefix(10)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseCrashTimestamp(from lines: [String]) -> Date? {
        guard let raw = firstValue(after: "Date/Time:", in: lines) else { return nil }
        let formatters: [DateFormatter] = [
            dateFormatter("yyyy-MM-dd HH:mm:ss.SSS Z"),
            dateFormatter("yyyy-MM-dd HH:mm:ss Z")
        ]
        for formatter in formatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }

    private func parseIPSTimestamp(headerJSON: [String: Any]?, payloadJSON: [String: Any]?) -> Date? {
        if let timestamp = headerJSON?["timestamp"] as? String ?? payloadJSON?["timestamp"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: timestamp) { return date }
            let fallback = ISO8601DateFormatter()
            if let date = fallback.date(from: timestamp) { return date }
        }
        return nil
    }

    private func firstValue(after prefix: String, in lines: [String]) -> String? {
        for line in lines {
            guard line.hasPrefix(prefix) else { continue }
            return line.replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private func parseVersionAndBuild(from versionField: String?) -> (version: String?, build: String?) {
        guard let raw = versionField?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (nil, nil)
        }

        guard let openParen = raw.lastIndex(of: "("),
              let closeParen = raw.lastIndex(of: ")"),
              openParen < closeParen else {
            return (raw, nil)
        }

        let versionPart = String(raw[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        let buildPart = String(raw[raw.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versionPart.isEmpty ? nil : versionPart
        let build = buildPart.isEmpty ? nil : buildPart
        return (version, build)
    }

    private func parseIPSVersionBuild(headerJSON: [String: Any]?, payloadJSON: [String: Any]?) -> (version: String?, build: String?) {
        var version = firstNonEmptyString(from: headerJSON, keys: ["app_version", "appVersion", "appVersionString"])
            ?? firstNonEmptyString(from: payloadJSON, keys: ["app_version", "appVersion", "appVersionString"])
        var build = firstNonEmptyString(from: headerJSON, keys: ["build_version", "app_build", "appBuild", "buildVersion"])
            ?? firstNonEmptyString(from: payloadJSON, keys: ["build_version", "app_build", "appBuild", "buildVersion"])

        if let bundleInfo = headerJSON?["bundleInfo"] as? [String: Any] {
            version = version ?? firstNonEmptyString(from: bundleInfo, keys: ["CFBundleShortVersionString", "CFBundleVersionString"])
            build = build ?? firstNonEmptyString(from: bundleInfo, keys: ["CFBundleVersion"])
        }
        if let bundleInfo = payloadJSON?["bundleInfo"] as? [String: Any] {
            version = version ?? firstNonEmptyString(from: bundleInfo, keys: ["CFBundleShortVersionString", "CFBundleVersionString"])
            build = build ?? firstNonEmptyString(from: bundleInfo, keys: ["CFBundleVersion"])
        }

        if build == nil, let currentVersion = version {
            let parsed = parseVersionAndBuild(from: currentVersion)
            version = parsed.version ?? currentVersion
            build = parsed.build
        }

        return (version, build)
    }

    private func firstNonEmptyString(from dictionary: [String: Any]?, keys: [String]) -> String? {
        guard let dictionary else { return nil }
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private func machineArchitecture() -> String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }

        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: machine)
    }
}

private struct ParsedCrash {
    let crashTimestamp: Date?
    let terminationSummary: String
    let topFrames: [String]
    let metadata: [String: String]
    let appVersion: String?
    let appBuild: String?
}
