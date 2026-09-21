import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Grok source: runtime factory and palette. The UI-free
// descriptor lives in GrokSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for grok (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let grok = SessionSourceAdapter(
        descriptor: .grok,
        appearance: SessionSourceAppearance(
            // Slate blue-grey, echoing xAI's monochrome mark while staying clear of
            // Codex's deep blue and Cursor's teal.
            brandHue: .calibrated(red: 0.35, green: 0.40, blue: 0.52),
            monochromeWhite: 0.62,
            onboardingAccent: { _ in Color.agentGrok },
            // K10: same exhausted ⌘-range as Hermes/Kimi.
            otherAgentPill: PillSpec(color: Color.agentGrok, shortcut: nil)
        ),
        makeRuntime: {
            let indexer = GrokSessionIndexer()
            return SourceRuntime(
                source: .grok,
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
                        let reason: GrokSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in GrokSessionParser.parseFileFull(at: url, allowLargeFile: true) }
                )
            )
        }
    )
}
