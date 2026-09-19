import Foundation

/// Persisted Qwen keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum QwenPreferencesKey {
    static let enabled = "AgentEnabledQwen"
    static let cliAvailable = "QwenCLIAvailable"
    static let sessionsRootOverride = "QwenSessionsRootOverride"
    static let includeSessions = "IncludeQwenSessions"
}

extension SessionSourceDescriptor {
    static let qwen: SessionSourceDescriptor = {
        // Routes through the one resolver so availability cannot disagree with the
        // root discovery and resume eligibility actually read. See
        // `QwenSessionDiscovery.resolvedSessionsRoot`.
        let projectsRoot: (AvailabilityContext) -> URL = { context in
            QwenSessionDiscovery.resolvedSessionsRoot(
                customRoot: context.customRoot(QwenPreferencesKey.sessionsRootOverride),
                homeDirectory: context.homeDirectory,
                environment: context.environment,
                directoryExists: { context.directoryExists($0) }
            )
        }

        return SessionSourceDescriptor(
            source: .qwen,
            telemetry: .allUnavailable("dense per-call token telemetry is retained but unparsed (Plan C)"),
            shortLabel: "Qwen Code",
            badgeInitials: "QW",
            enablementKey: QwenPreferencesKey.enabled,
            cliAvailableKey: QwenPreferencesKey.cliAvailable,
            rootOverrideKeys: [QwenPreferencesKey.sessionsRootOverride],
            includeKey: QwenPreferencesKey.includeSessions,
            binaryNames: ["qwen"],
            isBinaryInstalled: { $0.detectBinary("qwen") },
            isAvailable: { context in
                context.directoryExists(projectsRoot(context)) || context.detectBinary("qwen")
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { QwenSessionParser.parseFileFull(at: $0) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    let value = defaults.string(forKey: QwenPreferencesKey.sessionsRootOverride)
                    let discovery = QwenSessionDiscovery(customRoot: value?.isEmpty == false ? value : nil)
                    var byID: [String: URL] = [:]
                    for url in discovery.discoverSessionFiles() {
                        guard let id = QwenSessionDiscovery.sessionID(forTranscript: url), byID[id] == nil else {
                            continue
                        }
                        byID[id] = url
                    }
                    return byID
                },
                sessionForBackfill: { id, url in
                    QwenSessionParser.parseFileFull(at: url)
                        ?? SessionArchiveBackfill.minimalSession(source: .qwen, id: id, url: url)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Qwen Code"
        )
    }()
}
