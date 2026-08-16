import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let kimi: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("kimi")
        }
        return SessionSourceDescriptor(
            source: .kimi,
            shortLabel: "Kimi Code",
            badgeInitials: "KM",
            // Indigo-violet accent, distinct from Codex's blue and OpenCode's purple.
            brandHue: .calibrated(red: 0.46, green: 0.34, blue: 0.82),
            monochromeWhite: 0.66,
            onboardingAccent: { _ in Color.agentKimi },
            enablementKey: PreferencesKey.Agents.kimiEnabled,
            cliAvailableKey: PreferencesKey.kimiCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.kimiSessionsRootOverride],
            includeKey: PreferencesKey.Include.kimi,
            binaryNames: ["kimi"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.kimiSessionsRootOverride)
                let root = KimiSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in KimiSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.kimiSessionsRootOverride)
                    let discovery = KimiSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = KimiSessionDiscovery.sessionID(forWireFile: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    KimiSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .kimi, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Kimi Code",
            // K10: ⌘1–⌘9 fully allocated (Codex=1, Claude=2, … Pi=9), so Kimi has none.
            otherAgentPill: PillSpec(color: Color.agentKimi, shortcut: nil)
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for kimi (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let kimi = SessionSourceAdapter(
        descriptor: .kimi,
        makeRuntime: {
            let indexer = KimiSessionIndexer()
            return SourceRuntime(
                source: .kimi,
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
                        let reason: KimiSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in KimiSessionParser.parseFileFull(at: url, allowLargeFile: true) }
                )
            )
        }
    )
}
