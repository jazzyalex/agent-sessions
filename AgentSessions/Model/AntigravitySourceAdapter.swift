import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Antigravity source: runtime factory and palette. The UI-free
// descriptor lives in AntigravitySourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for antigravity (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let antigravity = SessionSourceAdapter(
        descriptor: .antigravity,
        appearance: SessionSourceAppearance(
            // Teal. Calibrated to what `systemTeal` drew in light mode through macOS 15;
            // pinned as a literal so the brand no longer moves when Apple restyles the
            // system palette (macOS 26 changed `systemTeal`).
            brandHue: .calibrated(red: 0.289820, green: 0.617301, blue: 0.718147),
            monochromeWhite: 0.6,
            onboardingAccent: { $0.accentBlue },
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .antigravity)),
                                     shortcut: "3")
        ),
        makeRuntime: {
            let indexer = AntigravitySessionIndexer()
            return SourceRuntime(
                source: .antigravity,
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
                        let reason: AntigravitySessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in AntigravitySessionParser.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
