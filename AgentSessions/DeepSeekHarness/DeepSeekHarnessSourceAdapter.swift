import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the DeepSeekHarness source: runtime factory and palette. The UI-free
// descriptor lives in DeepSeekHarnessSourceDescriptor.swift and is shared with the Linux core.

extension SessionSourceAdapter {
    static let deepseekHarness = SessionSourceAdapter(
        descriptor: .deepseekHarness,
        appearance: SessionSourceAppearance(
            // DSH true-color brand ink #4D6BFE. The shared calibrated path preserves
            // that light appearance while deriving the app's adaptive dark variant.
            brandHue: .calibrated(red: 77.0 / 255.0, green: 107.0 / 255.0, blue: 254.0 / 255.0),
            monochromeWhite: 0.62,
            onboardingAccent: { _ in
                Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .deepseekHarness))
            },
            otherAgentPill: PillSpec(
                color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .deepseekHarness)),
                shortcut: nil
            )
        ),
        makeRuntime: {
            let indexer = DeepSeekHarnessSessionIndexer()
            return SourceRuntime(
                source: .deepseekHarness,
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
                    searchLivePathSnapshots: .provider { indexer.searchLivePathSnapshot },
                    refresh: { mode, trigger, profile in
                        indexer.refresh(mode: mode, trigger: trigger, executionProfile: profile)
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: DeepSeekHarnessSessionIndexer.ReloadReason
                        switch trigger {
                        case .selection: reason = .selection
                        case .monitor: reason = .focusedSessionMonitor
                        case .manual: reason = .manualRefresh
                        }
                        indexer.reloadSession(id: id, force: force, reason: reason)
                    }
                ),
                searchAdapter: .init(
                    transcriptCache: indexer.searchTranscriptCache,
                    update: { indexer.updateSession($0) },
                    parseFull: { url, _ in DeepSeekHarnessSessionParser.parseFileFull(at: url) }
                )
            )
        }
    )
}
