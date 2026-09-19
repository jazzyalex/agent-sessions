import Foundation

extension SessionSourceDescriptor {
    static let copilot: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("copilot")
        }
        return SessionSourceDescriptor(
            source: .copilot,
            // Configuration is stated outright by `session.model_change` (new model,
            // previous model, reasoning effort). Tokens arrive only in the
            // end-of-process `session.shutdown` summary, so a running session shows
            // none, and spend can never be attributed to the configuration that
            // incurred it.
            telemetry: TelemetryCapabilities(
                configuration: .supported,
                tokens: .partial("only an end-of-process summary; no per-turn attribution"),
                cost: .partial("priced from the session summary, not per turn"),
                weeklyQuota: .unavailable("no account-level quota feed")
            ),
            shortLabel: "Copilot",
            badgeInitials: "CP",
            enablementKey: PreferencesKey.Agents.copilotEnabled,
            cliAvailableKey: PreferencesKey.copilotCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.copilotSessionsRootOverride],
            includeKey: PreferencesKey.Include.copilot,
            binaryNames: ["copilot"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.copilotSessionsRootOverride)
                let root = CopilotSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in CopilotSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride)
                    let discovery = CopilotSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        let base = url.deletingPathExtension().lastPathComponent
                        if !base.isEmpty { map[base] = url }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    CopilotSessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .copilot, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Copilot CLI"
        )
    }()
}
