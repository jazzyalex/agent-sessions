import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let deepseekHarness: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { $0.detectBinary("dsh") }
        return SessionSourceDescriptor(
            source: .deepseekHarness,
            telemetry: .allUnavailable("DSH session records do not expose audited account telemetry"),
            shortLabel: "DeepSeek Harness",
            badgeInitials: "DS",
            brandHue: .calibrated(red: 0.18, green: 0.45, blue: 0.82),
            monochromeWhite: 0.62,
            onboardingAccent: { _ in Color(red: 0.18, green: 0.45, blue: 0.82) },
            enablementKey: DeepSeekHarnessSettings.Keys.enabled,
            cliAvailableKey: DeepSeekHarnessSettings.Keys.cliAvailable,
            rootOverrideKeys: [DeepSeekHarnessSettings.Keys.rootOverride],
            includeKey: DeepSeekHarnessSettings.Keys.include,
            binaryNames: ["dsh"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(DeepSeekHarnessSettings.Keys.rootOverride)
                let root = DeepSeekHarnessDiscovery(customRoot: custom,
                                                     homeDirectory: ctx.homeDirectory,
                                                     environment: ctx.environment).sessionsRoot()
                return ctx.directoryExists(root) || isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { DeepSeekHarnessSessionParser.parseFileFull(at: $0) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            logicalFileStat: { url in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate else { return nil }
                return SessionFileStat(mtime: Int64(date.timeIntervalSince1970), size: Int64(values.fileSize ?? 0))
            },
            archive: nil,
            supportsResume: false,
            resumeAgentLabel: nil,
            otherAgentPill: PillSpec(color: Color(red: 0.18, green: 0.45, blue: 0.82), shortcut: nil)
        )
    }()
}

extension SessionSourceAdapter {
    static let deepseekHarness = SessionSourceAdapter(
        descriptor: .deepseekHarness,
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
