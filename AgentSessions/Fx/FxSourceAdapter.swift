import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the Fx source: runtime factory and palette. The UI-free
// descriptor lives in FxSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for fx (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let fx = SessionSourceAdapter(
        descriptor: .fx,
        appearance: SessionSourceAppearance(
            // fx ships no usable brand chroma — its mark and site are monochrome —
            // so this slot is a free choice, not an inherited color: crimson,
            // clear of OpenClaw's orange and Codex's deep blue.
            brandHue: .calibrated(red: 0.80, green: 0.22, blue: 0.27),
            monochromeWhite: 0.60,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .fx)) },
            // K10: same exhausted ⌘-range as Hermes/Kimi/Grok/Qwen.
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .fx)),
                                     shortcut: nil)
        ),
        makeRuntime: {
            let indexer = FxSessionIndexer()
            return SourceRuntime(
                source: .fx,
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
                        let reason: FxSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in FxSessionParser.parseFileFull(at: url, allowLargeFile: true) }
                )
            )
        }
    )
}
