import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Hermes source: runtime factory and palette. The UI-free
// descriptor lives in HermesSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for hermes (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let hermes = SessionSourceAdapter(
        descriptor: .hermes,
        appearance: SessionSourceAppearance(
            // Olive-gold accent, shifted away from Claude/OpenClaw warm oranges.
            brandHue: .calibrated(red: 0.62, green: 0.64, blue: 0.18),
            monochromeWhite: 0.72,
            onboardingAccent: { _ in Color.agentHermes },
            // K10: ⌘3–⌘9 were already allocated when Hermes shipped, so it has no shortcut.
            otherAgentPill: PillSpec(color: TranscriptColorSystem.agentBrandAccent(source: .hermes),
                                     shortcut: nil)
        ),
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
