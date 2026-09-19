import Foundation

extension SessionSourceDescriptor {
    static let opencode: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("opencode")
        }
        return SessionSourceDescriptor(
            source: .opencode,
            telemetry: .allUnavailable("transcript format not audited for telemetry"),
            shortLabel: "OpenCode",
            badgeInitials: "OC",
            enablementKey: PreferencesKey.Agents.openCodeEnabled,
            cliAvailableKey: PreferencesKey.openCodeCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.opencodeSessionsRootOverride],
            includeKey: PreferencesKey.Include.opencode,
            binaryNames: ["opencode"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.opencodeSessionsRootOverride)
                // Check opencode.db first (v1.2+ SQLite backend), through the same injected
                // environment as the legacy JSON-root probe.
                if OpenCodeBackendDetector.isSQLiteAvailable(customRoot: custom,
                                                             fileProbe: ctx.fileProbe,
                                                             homeDirectory: ctx.homeDirectory) { return true }
                let root = OpenCodeSessionDiscovery(customRoot: custom,
                                                    fileProbe: ctx.fileProbe,
                                                    homeDirectory: ctx.homeDirectory).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in OpenCodeSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: { url, sessionID in
                guard url.lastPathComponent == "opencode.db" else {
                    return OpenCodeSessionParser.parseFileFull(at: url)
                }
                return OpenCodeSqliteReader.loadFullSession(customRoot: url.path, sessionID: sessionID)
            },
            searchUsesIdentityAtURL: { $0.lastPathComponent == "opencode.db" },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
                    let discovery = OpenCodeSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        let base = url.deletingPathExtension().lastPathComponent
                        if base.isEmpty { continue }
                        map[base] = url
                        if base.hasPrefix("ses_") {
                            map[String(base.dropFirst("ses_".count))] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    OpenCodeSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .opencode, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "OpenCode"
        )
    }()
}
