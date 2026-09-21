import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Cline source: runtime factory and palette. The UI-free
// descriptor lives in ClineSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for cline (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let cline = SessionSourceAdapter(
        descriptor: .cline,
        appearance: SessionSourceAppearance(
            // Sky blue, clear of Codex's deep blue, Cursor's teal and Kimi/Qwen violets.
            brandHue: .calibrated(red: 0.22, green: 0.58, blue: 0.90),
            monochromeWhite: 0.64,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .cline)) },
            // K10: same exhausted ⌘-range as Hermes/Kimi/Grok/Qwen/Devin/fx.
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .cline)),
                                     shortcut: nil)
        ),
        makeRuntime: {
            let indexer = ClineSessionIndexer()
            return SourceRuntime(
                source: .cline,
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
                        let reason: ClineSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in ClineSessionParser.parseFileFull(at: url) }
                )
            )
        }
    )
}
