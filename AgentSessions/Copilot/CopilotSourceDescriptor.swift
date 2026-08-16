import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let copilot: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("copilot")
        }
        return SessionSourceDescriptor(
            source: .copilot,
            shortLabel: "Copilot",
            badgeInitials: "CP",
            // Magenta-ish.
            brandHue: .calibrated(red: 0.90, green: 0.20, blue: 0.60),
            monochromeWhite: 0.75,
            onboardingAccent: { _ in Color(red: 0.82, green: 0.36, blue: 0.78) },
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
            resumeAgentLabel: "Copilot CLI",
            otherAgentPill: PillSpec(color: Color.agentCopilot, shortcut: "5")
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for copilot (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let copilot = SessionSourceAdapter(
        descriptor: .copilot,
        makeRuntime: {
            let indexer = CopilotSessionIndexer()
            return SourceRuntime(
                source: .copilot,
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
                        let reason: CopilotSessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in CopilotSessionParser.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
