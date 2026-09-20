import Foundation

extension SessionSourceDescriptor {
    static let droid: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("droid")
        }
        return SessionSourceDescriptor(
            source: .droid,
            telemetry: .allUnavailable("transcript format not audited for telemetry"),
            shortLabel: "Droid",
            badgeInitials: "D",
            enablementKey: PreferencesKey.Agents.droidEnabled,
            cliAvailableKey: PreferencesKey.droidCLIAvailable,
            // K3: the only source with two root-override keys. Order matters — the
            // sessions root is the primary probe, the projects root the fallback.
            rootOverrideKeys: [PreferencesKey.Paths.droidSessionsRootOverride,
                               PreferencesKey.Paths.droidProjectsRootOverride],
            includeKey: PreferencesKey.Include.droid,
            binaryNames: ["droid"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let sessionsCustom = ctx.customRoot(PreferencesKey.Paths.droidSessionsRootOverride)
                let projectsCustom = ctx.customRoot(PreferencesKey.Paths.droidProjectsRootOverride)
                let discovery = DroidSessionDiscovery(customSessionsRoot: sessionsCustom,
                                                      customProjectsRoot: projectsCustom)
                if ctx.directoryExists(discovery.sessionsRoot()) { return true }
                if ctx.directoryExists(discovery.projectsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            // Availability-gated since 2026-08-28. Droid is not a supported source: there is
            // no subscription here to test its sessions against, and it stays unsupported
            // until a steward takes it on, so it must not be on for users who do not run it.
            // This was `.always` (K7). That only ever reached installs seeded *before* droid
            // joined the registry — `seedIfNeeded` writes every other install's key from
            // availability — so upgraders were the one cohort left with droid silently on.
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in DroidSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            makeDiscovery: { ctx in DroidSessionDiscovery(customSessionsRoot: ctx.customRoot(PreferencesKey.Paths.droidSessionsRootOverride),
                                      customProjectsRoot: ctx.customRoot(PreferencesKey.Paths.droidProjectsRootOverride)) },
            parseLightweightByPath: { DroidSessionParser.parseFile(at: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let sessionsCustom = defaults.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride)
                    let projectsCustom = defaults.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride)
                    let discovery = DroidSessionDiscovery(customSessionsRoot: sessionsCustom?.isEmpty == false ? sessionsCustom : nil,
                                                          customProjectsRoot: projectsCustom?.isEmpty == false ? projectsCustom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = DroidSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    DroidSessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .droid, id: sessionID, url: upstreamURL)
                }
            ),
            // Droid never resumes: `canResumeSession` leaves it to the `default: false`
            // arm, and `resumeAgentLabel` has no arm for it either.
            supportsResume: false,
            resumeAgentLabel: nil
        )
    }()
}
