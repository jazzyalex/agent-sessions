import Foundation

extension SessionSourceDescriptor {
    static let hermes: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("hermes")
        }
        return SessionSourceDescriptor(
            source: .hermes,
            telemetry: .allUnavailable("transcript format not audited for telemetry"),
            shortLabel: "Hermes",
            badgeInitials: "HM",
            enablementKey: PreferencesKey.Agents.hermesEnabled,
            cliAvailableKey: PreferencesKey.hermesCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.hermesSessionsRootOverride],
            includeKey: PreferencesKey.Include.hermes,
            binaryNames: ["hermes"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.hermesSessionsRootOverride)
                let discovery = HermesSessionDiscovery(customRoot: custom,
                                                       fileProbe: ctx.fileProbe,
                                                       homeDirectory: ctx.homeDirectory)
                // Preserve the pre-registry enablement policy: a legacy sessions directory
                // or the CLI binary enables Hermes. The current state.db is indexed when
                // Hermes is enabled, but state.db alone was not an availability signal.
                if ctx.directoryExists(discovery.sessionsRoot()) {
                    return true
                }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in HermesSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: { url, sessionID in
                guard url.pathExtension.lowercased() == "db" else {
                    return HermesSessionParser.parseFileFull(at: url)
                }
                return HermesStateDBReader.loadFullSession(dbURL: url, sessionID: sessionID)
            },
            searchUsesIdentityAtURL: { $0.pathExtension.lowercased() == "db" },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.hermesSessionsRootOverride)
                    let discovery = HermesSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = HermesSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    HermesSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .hermes, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Hermes"
        )
    }()
}
