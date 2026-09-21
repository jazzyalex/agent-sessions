import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Droid source: runtime factory and palette. The UI-free
// descriptor lives in DroidSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for droid (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let droid = SessionSourceAdapter(
        descriptor: .droid,
        appearance: SessionSourceAppearance(
            // Green brand (disambiguation handled via styling, not hue).
            brandHue: .calibrated(red: 0.16, green: 0.68, blue: 0.28),
            monochromeWhite: 0.8,
            onboardingAccent: { _ in Color(red: 0.26, green: 0.72, blue: 0.38) },
            otherAgentPill: PillSpec(color: Color.agentDroid, shortcut: "6")
        ),
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
