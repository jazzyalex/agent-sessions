import Foundation

// Codex lives in `Model/` rather than a `Codex/` folder because it has none: its parser,
// discovery and indexer predate the per-source folder convention and sit in `Services/`.

extension SessionSourceDescriptor {
    static let codex: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("codex")
        }
        return SessionSourceDescriptor(
            source: .codex,
            // turn_context states the effective model AND effort for every turn, so
            // the configuration timeline is exact. Tokens are partial only because
            // legacy rollouts exist that record a total with no component breakdown;
            // those can report a token count but cannot be priced.
            telemetry: TelemetryCapabilities(
                configuration: .supported,
                tokens: .partial("legacy total-only logs have no component breakdown"),
                cost: .partial("legacy total-only logs cannot be priced"),
                weeklyQuota: .partial("estimated from account-wide quota calibration; other-device activity is unobservable")
            ),
            shortLabel: "Codex",
            badgeInitials: "CX",
            enablementKey: PreferencesKey.Agents.codexEnabled,
            cliAvailableKey: PreferencesKey.codexCLIAvailable,
            // Historical, un-namespaced key: "SessionsRootOverride" (K1 — frozen forever).
            rootOverrideKeys: [PreferencesKey.Paths.codexSessionsRootOverride],
            includeKey: PreferencesKey.Include.codex,
            binaryNames: ["codex"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.codexSessionsRootOverride)
                let root = CodexSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in CodexSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            makeDiscovery: { ctx in CodexSessionDiscovery(customRoot: ctx.customRoot(PreferencesKey.Paths.codexSessionsRootOverride)) },
            parseLightweightByPath: { CodexSessionParser.parseFile(at: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.codexSessionsRootOverride)
                    let discovery = CodexSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        map[SessionArchiveBackfill.sha256Hex(url.path)] = url
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    // SessionIndexer's lightweight parsing helpers are currently private; for
                    // backfill we only need a stable upstream path so the archive can be
                    // created. Metadata will be refreshed on later scans.
                    SessionArchiveBackfill.minimalSession(source: .codex, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Codex CLI"
        )
    }()
}
