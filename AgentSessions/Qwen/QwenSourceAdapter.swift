import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Qwen source: runtime factory and palette. The UI-free
// descriptor lives in QwenSourceDescriptor.swift and is shared with the Linux core.

extension SessionSourceAdapter {
    static let qwen = SessionSourceAdapter(
        descriptor: .qwen,
        appearance: SessionSourceAppearance(
            brandHue: .calibrated(red: 0.45, green: 0.31, blue: 0.77),
            monochromeWhite: 0.61,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .qwen)) },
            otherAgentPill: PillSpec(
                color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .qwen)),
                shortcut: nil
            )
        ),
        makeRuntime: {
            let indexer = QwenSessionIndexer()
            return SourceRuntime(
                source: .qwen,
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
                        let reason: QwenSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in QwenSessionParser.parseFileFull(at: url) }
                )
            )
        }
    )
}
