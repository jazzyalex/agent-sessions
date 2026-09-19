import Foundation

extension SessionSourceDescriptor {
    static let kimi: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("kimi")
        }
        return SessionSourceDescriptor(
            source: .kimi,
            telemetry: .allUnavailable("measured per-turn token records are retained but unparsed (Plan C)"),
            shortLabel: "Kimi Code",
            badgeInitials: "KM",
            enablementKey: PreferencesKey.Agents.kimiEnabled,
            cliAvailableKey: PreferencesKey.kimiCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.kimiSessionsRootOverride],
            includeKey: PreferencesKey.Include.kimi,
            binaryNames: ["kimi"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.kimiSessionsRootOverride)
                let root = KimiSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in KimiSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.kimiSessionsRootOverride)
                    let discovery = KimiSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = KimiSessionDiscovery.sessionID(forWireFile: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    KimiSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .kimi, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Kimi Code"
        )
    }()
}
