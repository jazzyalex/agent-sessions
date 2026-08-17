import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let hermes: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("hermes")
        }
        return SessionSourceDescriptor(
            source: .hermes,
            shortLabel: "Hermes",
            badgeInitials: "HM",
            // Olive-gold accent, shifted away from Claude/OpenClaw warm oranges.
            brandHue: .calibrated(red: 0.62, green: 0.64, blue: 0.18),
            monochromeWhite: 0.72,
            onboardingAccent: { _ in Color.agentHermes },
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
            resumeAgentLabel: "Hermes",
            // K10: ⌘3–⌘9 were already allocated when Hermes shipped, so it has no shortcut.
            otherAgentPill: PillSpec(color: TranscriptColorSystem.agentBrandAccent(source: .hermes),
                                     shortcut: nil)
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for hermes (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let hermes = SessionSourceAdapter(
        descriptor: .hermes,
        makeRuntime: {
            let indexer = HermesSessionIndexer()
            return SourceRuntime(
                source: .hermes,
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
                    searchIdentitySnapshots: .provider { indexer.searchIdentitySnapshot },
                    refresh: { mode, trigger, profile in
                        indexer.refresh(mode: mode, trigger: trigger, executionProfile: profile)
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: HermesSessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in
                        if url.pathExtension.lowercased() == "db", !forcedID.isEmpty {
                            return HermesStateDBReader.loadFullSession(dbURL: url, sessionID: forcedID)
                        }
                        return HermesSessionParser.parseFileFull(at: url)
                    }
                )
            )
        }
    )
}
