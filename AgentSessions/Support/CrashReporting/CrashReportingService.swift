import Foundation

struct CrashDiagnosticsSnapshot: Sendable {
    let pendingCount: Int
    let lastDetectedAt: Date?
    let lastSendAt: Date?
    let lastSendError: String?
}

actor CrashReportingService {
    static let shared = CrashReportingService()
    private static let maxSeenCrashHistory = 200

    private let store: CrashReportStore
    private let detector: CrashReportDetector
    private let userDefaults: UserDefaults
    private let nowProvider: () -> Date
    private var didRunLaunchScan = false

    init(store: CrashReportStore = CrashReportStore(maxPendingCount: 1),
         detector: CrashReportDetector = CrashReportDetector(),
         userDefaults: UserDefaults = .standard,
         nowProvider: @escaping () -> Date = Date.init) {
        self.store = store
        self.detector = detector
        self.userDefaults = userDefaults
        self.nowProvider = nowProvider
    }

    func detectAndQueueOnLaunch() async -> Int {
        guard !didRunLaunchScan else { return 0 }
        didRunLaunchScan = true

        let detected = detector.detectRecentCrashes()
        guard !detected.isEmpty else { return 0 }

        let seenHistory = loadedSeenCrashIDHistory()
        let seenIDs = Set(seenHistory)
        let filtered = detected.filter { !seenIDs.contains($0.id) }
        guard !filtered.isEmpty else { return 0 }

        guard let newestUnseen = filtered.first else { return 0 }
        await store.enqueue(contentsOf: [newestUnseen])
        return 1
    }

    func diagnosticsSnapshot() async -> CrashDiagnosticsSnapshot {
        let pendingCount = await store.pendingCount()
        let lastDetectedAt = await store.latestDetectedAt()
        let lastSendTimestamp = userDefaults.double(forKey: PreferencesKey.Diagnostics.lastSendAt)
        let lastSendAt = lastSendTimestamp > 0 ? Date(timeIntervalSince1970: lastSendTimestamp) : nil

        return CrashDiagnosticsSnapshot(
            pendingCount: pendingCount,
            lastDetectedAt: lastDetectedAt,
            lastSendAt: lastSendAt,
            lastSendError: userDefaults.string(forKey: PreferencesKey.Diagnostics.lastSendError)
        )
    }

    func pendingReports() async -> [CrashReportEnvelope] {
        await store.pending()
    }

    func clearPendingReports() async {
        let pending = await store.pending()
        let pendingIDsByRecency = pending.map(\.id).filter { !$0.isEmpty }
        if !pendingIDsByRecency.isEmpty {
            let seenHistory = loadedSeenCrashIDHistory()
            let updatedSeenHistory = mergedSeenCrashIDHistory(existing: seenHistory, newlySeenIDsByRecency: pendingIDsByRecency)
            persistSeenCrashIDHistory(updatedSeenHistory, lastSeenID: pendingIDsByRecency.first)
        }
        await store.clear()
    }

    func exportLatestPendingReport(to url: URL) async throws {
        let pending = await store.pending()
        guard let report = pending.first else {
            throw CrashReportStoreError.nothingToExport
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: [.atomic])
    }

    func supportEmailDraftURL(recipient: String) async -> URL? {
        let pending = await store.pending()
        let latest = pending.first?.redactedForUpload()

        let subject = buildEmailSubject(report: latest)
        let body = buildEmailBody(report: latest, pendingCount: pending.count)
        return CrashEmailDraftBuilder.mailtoURL(recipient: recipient, subject: subject, body: body)
    }

    func markEmailDraftOpened() {
        userDefaults.set(nowProvider().timeIntervalSince1970, forKey: PreferencesKey.Diagnostics.lastSendAt)
        userDefaults.removeObject(forKey: PreferencesKey.Diagnostics.lastSendError)
    }

    func setLastEmailError(_ message: String?) {
        if let message, !message.isEmpty {
            userDefaults.set(message, forKey: PreferencesKey.Diagnostics.lastSendError)
        } else {
            userDefaults.removeObject(forKey: PreferencesKey.Diagnostics.lastSendError)
        }
    }

    private func loadedSeenCrashIDHistory() -> [String] {
        var history = userDefaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        history = history.filter { !$0.isEmpty }

        if let legacy = userDefaults.string(forKey: PreferencesKey.Diagnostics.lastSeenCrashID), !legacy.isEmpty {
            history.removeAll { $0 == legacy }
            history.insert(legacy, at: 0)
        }

        return deduplicatedIDsPreservingOrder(history)
    }

    private func mergedSeenCrashIDHistory(existing: [String], newlySeenIDsByRecency: [String]) -> [String] {
        var merged: [String] = []
        merged.reserveCapacity(existing.count + newlySeenIDsByRecency.count)
        var seen: Set<String> = []

        for id in newlySeenIDsByRecency where !id.isEmpty {
            if seen.insert(id).inserted {
                merged.append(id)
            }
        }

        for id in existing where !id.isEmpty {
            if seen.insert(id).inserted {
                merged.append(id)
            }
        }

        if merged.count > Self.maxSeenCrashHistory {
            return Array(merged.prefix(Self.maxSeenCrashHistory))
        }
        return merged
    }

    private func persistSeenCrashIDHistory(_ seenHistory: [String], lastSeenID: String?) {
        let normalized = deduplicatedIDsPreservingOrder(seenHistory.filter { !$0.isEmpty })
        let capped = Array(normalized.prefix(Self.maxSeenCrashHistory))

        userDefaults.set(capped, forKey: PreferencesKey.Diagnostics.seenCrashIDs)
        if let lastSeenID, !lastSeenID.isEmpty {
            userDefaults.set(lastSeenID, forKey: PreferencesKey.Diagnostics.lastSeenCrashID)
        } else if let fallbackLastSeen = capped.first {
            userDefaults.set(fallbackLastSeen, forKey: PreferencesKey.Diagnostics.lastSeenCrashID)
        } else {
            userDefaults.removeObject(forKey: PreferencesKey.Diagnostics.lastSeenCrashID)
        }
    }

    private func deduplicatedIDsPreservingOrder(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var deduplicated: [String] = []
        deduplicated.reserveCapacity(ids.count)

        for id in ids where !id.isEmpty {
            if seen.insert(id).inserted {
                deduplicated.append(id)
            }
        }

        return deduplicated
    }

    private func buildEmailSubject(report: CrashReportEnvelope?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: nowProvider())

        if let report {
            return "Agent Sessions Crash Report [\(stamp)] - \(report.id)"
        }
        return "Agent Sessions Crash Report [\(stamp)]"
    }

    private func buildEmailBody(report: CrashReportEnvelope?, pendingCount: Int) -> String {
        var lines: [String] = []
        lines.append("Hi Alex,")
        lines.append("")
        lines.append("I am sending a crash report from Agent Sessions.")
        lines.append("Pending crash reports in queue: \(pendingCount)")
        lines.append("")

        guard let report else {
            lines.append("No pending crash report was available when this draft was created.")
            lines.append("")
            lines.append("Thanks.")
            return lines.joined(separator: "\n")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(report),
           let json = String(data: data, encoding: .utf8) {
            lines.append("Crash Report JSON")
            lines.append("-----------------")
            lines.append(json)
        } else {
            lines.append("Failed to encode crash report JSON.")
        }

        lines.append("")
        lines.append("Thanks.")
        return lines.joined(separator: "\n")
    }
}
