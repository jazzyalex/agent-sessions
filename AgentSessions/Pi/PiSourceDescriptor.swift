import Foundation

extension SessionSourceDescriptor {
    static let pi: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("pi")
        }
        return SessionSourceDescriptor(
            source: .pi,
            // Pi states its configuration changes outright (`model_change`,
            // `thinking_level_change`) and gives every assistant message a complete
            // usage block — the most cooperative format of the four supported.
            telemetry: TelemetryCapabilities(
                configuration: .supported,
                tokens: .supported,
                cost: .supported,
                weeklyQuota: .unavailable("no account-level quota feed")
            ),
            shortLabel: "Pi",
            badgeInitials: "PI",
            enablementKey: PreferencesKey.Agents.piEnabled,
            cliAvailableKey: PreferencesKey.piCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.piSessionsRootOverride],
            includeKey: PreferencesKey.Include.pi,
            binaryNames: ["pi"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.piSessionsRootOverride)
                let root = PiSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in PiSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.piSessionsRootOverride)
                    let discovery = PiSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = PiSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    PiSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .pi, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Pi CLI"
        )
    }()
}
