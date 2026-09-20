import Foundation

extension SessionSourceDescriptor {
    static let cursor: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("agent") || ctx.detectBinary("cursor") || ctx.detectBinary("cursor-agent")
        }
        return SessionSourceDescriptor(
            source: .cursor,
            telemetry: .allUnavailable("transcript format not audited for telemetry"),
            shortLabel: "Cursor",
            badgeInitials: "CR",
            enablementKey: PreferencesKey.Agents.cursorEnabled,
            cliAvailableKey: PreferencesKey.cursorCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.cursorSessionsRootOverride],
            includeKey: PreferencesKey.Include.cursor,
            binaryNames: ["agent", "cursor", "cursor-agent"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.cursorSessionsRootOverride)
                let disc = CursorSessionDiscovery(customRoot: custom)
                // Also check the chats root (DB-only sessions live there). The live switch
                // does this before the shared sessions-root check, so the order is kept.
                if ctx.directoryExists(disc.chatsRoot()) { return true }
                if ctx.directoryExists(disc.sessionsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in CursorSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            makeDiscovery: { ctx in CursorSessionDiscovery(customRoot: ctx.customRoot(PreferencesKey.Paths.cursorSessionsRootOverride)) },
            parseLightweightByPath: { CursorSessionParser.parseFile(at: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
                    let discovery = CursorSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = CursorSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    CursorSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .cursor, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Cursor CLI"
        )
    }()
}
