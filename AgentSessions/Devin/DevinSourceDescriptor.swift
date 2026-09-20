import Foundation

/// Persisted Devin keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum DevinPreferencesKey {
    static let enabled = "AgentEnabledDevin"
    static let cliAvailable = "DevinCLIAvailable"
    static let sessionsRootOverride = "DevinSessionsRootOverride"
    static let includeSessions = "IncludeDevinSessions"
}

extension SessionSourceDescriptor {
    static let devin: SessionSourceDescriptor = {
        return SessionSourceDescriptor(
            source: .devin,
            telemetry: TelemetryCapabilities(
                configuration: .unavailable("session rows expose only scalar model/mode; no configuration timeline"),
                tokens: .unavailable("3000.6.7 audit: num_tokens is always null; num_tokens_preceding is a context cursor"),
                cost: .unavailable("3000.6.7 audit: cogs_json is configuration and recorded cost fields are always zero"),
                weeklyQuota: .unavailable("no account-level quota feed")
            ),
            shortLabel: "Devin CLI",
            badgeInitials: "DV",
            enablementKey: DevinPreferencesKey.enabled,
            cliAvailableKey: DevinPreferencesKey.cliAvailable,
            rootOverrideKeys: [DevinPreferencesKey.sessionsRootOverride],
            includeKey: DevinPreferencesKey.includeSessions,
            binaryNames: ["devin"],
            isBinaryInstalled: { ctx in
                ctx.detectBinary("devin")
            },
            isAvailable: { ctx in
                let custom = ctx.customRoot(DevinPreferencesKey.sessionsRootOverride)
                let discovery = DevinSessionDiscovery(customRoot: custom,
                                                      fileProbe: ctx.fileProbe,
                                                      homeDirectory: ctx.homeDirectory)
                if ctx.fileProbe.fileExists(atPath: discovery.databaseURL().path) { return true }
                return ctx.detectBinary("devin")
            },
            defaultEnabled: .whenAvailable,
            // Every session lives in one shared database, so path-identified
            // parsing is meaningless; search ingests through the identity
            // channel instead (SPEC §4, guide §5).
            parseFullByPath: nil,
            parseFullByIdentity: { url, sessionID in
                DevinSqliteReader.loadFullSession(databasePath: url.path, sessionID: sessionID)
            },
            searchUsesIdentityAtURL: { $0.pathExtension.lowercased() == "db" },
            // Archiving is a no-op: sessions are rows in a shared database,
            // so there is nothing per-session to copy out.
            listDatabaseSessions: { ctx in DevinSqliteReader.listSessions(databasePath: DevinSessionDiscovery(customRoot: ctx.customRoot(DevinPreferencesKey.sessionsRootOverride),
                                                                      fileProbe: ctx.fileProbe,
                                                                      homeDirectory: ctx.homeDirectory).databaseURL().path) },
            archive: nil,
            supportsResume: true,
            resumeAgentLabel: "Devin CLI"
        )
    }()
}
