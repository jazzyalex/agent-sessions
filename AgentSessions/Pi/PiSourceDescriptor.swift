import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let pi: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("pi")
        }
        return SessionSourceDescriptor(
            source: .pi,
            shortLabel: "Pi",
            badgeInitials: "PI",
            // Green-cyan accent, distinct from Gemini and Cursor.
            brandHue: .calibrated(red: 0.05, green: 0.62, blue: 0.48),
            monochromeWhite: 0.68,
            onboardingAccent: { _ in Color.agentPi },
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
            resumeAgentLabel: "Pi CLI",
            otherAgentPill: PillSpec(color: Color.agentPi, shortcut: "9")
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for pi (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let pi = SessionSourceAdapter(
        descriptor: .pi,
        makeRuntime: {
            let indexer = PiSessionIndexer()
            return SourceRuntime(
                source: .pi,
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
                        let reason: PiSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in PiSessionParser.parseFileFull(at: url, allowLargeFile: true) }
                )
            )
        }
    )
}
