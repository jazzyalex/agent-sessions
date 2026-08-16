import Foundation
import Combine
import SwiftUI
import AppKit

// OpenClaw has no top-level source folder, so its descriptor lives here.

extension SessionSourceDescriptor {
    static let openclaw: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("openclaw") || ctx.detectBinary("clawdbot")
        }
        return SessionSourceDescriptor(
            source: .openclaw,
            shortLabel: "OpenClaw",
            badgeInitials: "CL",
            // Coral-orange accent, kept warm but separated from Claude/Hermes.
            brandHue: .calibrated(red: 0.88, green: 0.33, blue: 0.20),
            monochromeWhite: 0.85,
            onboardingAccent: { _ in Color(red: 0.95, green: 0.55, blue: 0.18) },
            enablementKey: PreferencesKey.Agents.openClawEnabled,
            // K4: the only source with no CLI-availability key at all —
            // `AgentEnablement.storedBinaryPresence(for:)` returns nil outright rather than
            // reading defaults. Modeled as nil rather than fabricating a key name.
            cliAvailableKey: nil,
            // `PreferencesKey.Paths.openClawBinaryOverride` also exists but is a *binary
            // path* override, not a sessions root — deliberately not listed here.
            rootOverrideKeys: [PreferencesKey.Paths.openClawSessionsRootOverride],
            includeKey: PreferencesKey.Include.openclaw,
            binaryNames: ["openclaw", "clawdbot"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.openClawSessionsRootOverride)
                let root = OpenClawSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in OpenClawSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    defaults.register(defaults: [
                        PreferencesKey.Advanced.includeOpenClawDeletedSessions: true
                    ])
                    let custom = defaults.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride)
                    let includeDeleted = defaults.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
                    let discovery = OpenClawSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil,
                                                             includeDeleted: includeDeleted)
                    for url in discovery.discoverSessionFiles() {
                        if let s = OpenClawSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    OpenClawSessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .openclaw, id: sessionID, url: upstreamURL)
                }
            ),
            // OpenClaw never resumes (the `default: false` arm of `canResumeSession`).
            supportsResume: false,
            resumeAgentLabel: nil,
            otherAgentPill: PillSpec(color: Color.agentOpenClaw, shortcut: "7")
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for openclaw (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let openclaw = SessionSourceAdapter(
        descriptor: .openclaw,
        makeRuntime: {
            let indexer = OpenClawSessionIndexer()
            return SourceRuntime(
                source: .openclaw,
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
                    refresh: { mode, trigger, profile in
                        indexer.refresh(mode: mode, trigger: trigger, executionProfile: profile)
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: OpenClawSessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in OpenClawSessionParser.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
