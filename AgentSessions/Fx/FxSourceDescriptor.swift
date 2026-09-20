import Foundation

/// Persisted fx keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum FxPreferencesKey {
    static let enabled = "AgentEnabledFx"
    static let cliAvailable = "FxCLIAvailable"
    static let sessionsRootOverride = "FxSessionsRootOverride"
    static let includeSessions = "IncludeFxSessions"
}

extension SessionSourceDescriptor {
    static let fx: SessionSourceDescriptor = {
        // A bare `fx` on PATH is weak evidence by itself (the name is short and
        // generic), so require the CLI's own data directory alongside the binary —
        // injected, never `FileManager.default`.
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            guard ctx.detectBinary("fx") else { return false }
            let fxHome = ctx.homeDirectory.appendingPathComponent(".fx", isDirectory: true)
            return ctx.directoryExists(fxHome)
        }
        return SessionSourceDescriptor(
            source: .fx,
            telemetry: .allUnavailable("scalar model/effort metadata only; timeline and usage audit pending (Plan C)"),
            shortLabel: "fx",
            badgeInitials: "FX",
            enablementKey: FxPreferencesKey.enabled,
            cliAvailableKey: FxPreferencesKey.cliAvailable,
            rootOverrideKeys: [FxPreferencesKey.sessionsRootOverride],
            includeKey: FxPreferencesKey.includeSessions,
            binaryNames: ["fx"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(FxPreferencesKey.sessionsRootOverride)
                let discovery = FxSessionDiscovery(customRoot: custom,
                                                   fileProbe: ctx.fileProbe,
                                                   homeDirectory: ctx.homeDirectory)
                if !discovery.discoverSessionFiles().isEmpty { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in FxSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            makeDiscovery: { ctx in FxSessionDiscovery(customRoot: ctx.customRoot(FxPreferencesKey.sessionsRootOverride),
                                   fileProbe: ctx.fileProbe,
                                   homeDirectory: ctx.homeDirectory) },
            parseLightweightByPath: { FxSessionParser.parseFile(at: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: FxPreferencesKey.sessionsRootOverride)
                    let discovery = FxSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = FxSessionDiscovery.sessionID(forCheckpoint: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    FxSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .fx, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "fx"
        )
    }()
}
