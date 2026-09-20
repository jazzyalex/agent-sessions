import Foundation

extension SessionSourceDescriptor {
    static let claude: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("claude") || ctx.detectBinary("claude-code")
        }
        return SessionSourceDescriptor(
            source: .claude,
            // Claude stamps the model on the assistant record that used it and never
            // records a session-start configuration, so the "initial" one is inferred
            // from the first observation. Usage is per-message and complete, including
            // the 5m/1h cache-write split and the fast-mode tier.
            telemetry: TelemetryCapabilities(
                configuration: .partial("initial config is first-observed, not recorded at session start"),
                tokens: .supported,
                cost: .supported,
                weeklyQuota: .partial("raw quota evidence is available, but per-session attribution requires stable account identity")
            ),
            shortLabel: "Claude",
            badgeInitials: "CC",
            enablementKey: PreferencesKey.Agents.claudeEnabled,
            cliAvailableKey: PreferencesKey.claudeCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.claudeSessionsRootOverride],
            includeKey: PreferencesKey.Include.claude,
            binaryNames: ["claude", "claude-code"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.claudeSessionsRootOverride)
                let discovery = ClaudeSessionDiscovery(customRoot: custom,
                                                       fileProbe: ctx.fileProbe,
                                                       homeDirectory: ctx.homeDirectory)
                // Claude's multi-root probe knows about project folders the plain
                // sessions-root check would miss, while still honoring the injected
                // filesystem and home-directory seams.
                if discovery.hasDiscoverableSessionsRoot() { return true }
                if ctx.directoryExists(discovery.sessionsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in ClaudeSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            makeDiscovery: { ctx in ClaudeSessionDiscovery(customRoot: ctx.customRoot(PreferencesKey.Paths.claudeSessionsRootOverride),
                                       fileProbe: ctx.fileProbe,
                                       homeDirectory: ctx.homeDirectory) },
            parseLightweightByPath: { ClaudeSessionParser.parseFile(at: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride)
                    let discovery = ClaudeSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        map[SessionArchiveBackfill.sha256Hex(url.path)] = url
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    ClaudeSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .claude, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Claude Code"
        )
    }()
}
