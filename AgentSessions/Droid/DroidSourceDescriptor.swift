import Foundation
import Combine
import SwiftUI
import AppKit

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
            // Green brand (disambiguation handled via styling, not hue).
            brandHue: .calibrated(red: 0.16, green: 0.68, blue: 0.28),
            monochromeWhite: 0.8,
            onboardingAccent: { _ in Color(red: 0.26, green: 0.72, blue: 0.38) },
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
            resumeAgentLabel: nil,
            otherAgentPill: PillSpec(color: Color.agentDroid, shortcut: "6")
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for droid (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let droid = SessionSourceAdapter(
        descriptor: .droid,
        makeRuntime: {
            let indexer = DroidSessionIndexer()
            return SourceRuntime(
                source: .droid,
                indexerObject: indexer,
                handle: UnifiedSessionIndexer.ProviderHandle(
                    allSessions: indexer.$allSessions.eraseToAnyPublisher(),
                    isIndexing: indexer.$isIndexing.eraseToAnyPublisher(),
                    isProcessingTranscripts: indexer.$isProcessingTranscripts.eraseToAnyPublisher(),
                    filesProcessed: indexer.$filesProcessed.eraseToAnyPublisher(),
                    totalFiles: indexer.$totalFiles.eraseToAnyPublisher(),
                    indexingError: indexer.$indexingError.eraseToAnyPublisher(),
                    launchPhase: indexer.$launchPhase.eraseToAnyPublisher(),
                    currentSessions: { indexer.allSessions },
                    currentIsIndexing: { indexer.isIndexing },
                    currentLaunchPhase: { indexer.launchPhase },
                    searchIdentitySnapshots: .notApplicable,
                    refresh: { mode, trigger, profile in
                        indexer.refresh(mode: mode, trigger: trigger, executionProfile: profile)
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: DroidSessionIndexer.ReloadReason
                        switch trigger {
                        case .selection: reason = .selection
                        case .monitor: reason = .focusedSessionMonitor
                        case .manual: reason = .manualRefresh
                        }
                        indexer.reloadSession(id: id, force: force, reason: reason)
                    }
                ),
                // Transcribed verbatim from UnifiedSessionsView.init's adapter dictionary.
                searchAdapter: .init(
                    transcriptCache: indexer.searchTranscriptCache,
                    update: { indexer.updateSession($0) },
                    parseFull: { url, forcedID in DroidSessionParser.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
