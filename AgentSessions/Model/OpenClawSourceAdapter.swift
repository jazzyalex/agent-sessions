import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the OpenClaw source: runtime factory and palette. The UI-free
// descriptor lives in OpenClawSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for openclaw (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let openclaw = SessionSourceAdapter(
        descriptor: .openclaw,
        appearance: SessionSourceAppearance(
            // Coral-orange accent, kept warm but separated from Claude/Hermes.
            brandHue: .calibrated(red: 0.88, green: 0.33, blue: 0.20),
            monochromeWhite: 0.85,
            onboardingAccent: { _ in Color(red: 0.95, green: 0.55, blue: 0.18) },
            otherAgentPill: PillSpec(color: Color.agentOpenClaw, shortcut: "7")
        ),
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
                    searchIdentitySnapshots: .notApplicable,
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
