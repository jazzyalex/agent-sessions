import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let opencode: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("opencode")
        }
        return SessionSourceDescriptor(
            source: .opencode,
            shortLabel: "OpenCode",
            badgeInitials: "OC",
            // Purple. Passthrough, same reasoning as antigravity's systemTeal (K6).
            brandHue: .system(NSColor.systemPurple),
            monochromeWhite: 0.7,
            onboardingAccent: { _ in Color(red: 0.62, green: 0.52, blue: 0.96) },
            enablementKey: PreferencesKey.Agents.openCodeEnabled,
            cliAvailableKey: PreferencesKey.openCodeCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.opencodeSessionsRootOverride],
            includeKey: PreferencesKey.Include.opencode,
            binaryNames: ["opencode"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.opencodeSessionsRootOverride)
                // Check opencode.db first (v1.2+ SQLite backend), through the same injected
                // environment as the legacy JSON-root probe.
                if OpenCodeBackendDetector.isSQLiteAvailable(customRoot: custom,
                                                             fileProbe: ctx.fileProbe,
                                                             homeDirectory: ctx.homeDirectory) { return true }
                let root = OpenCodeSessionDiscovery(customRoot: custom,
                                                    fileProbe: ctx.fileProbe,
                                                    homeDirectory: ctx.homeDirectory).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in OpenCodeSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: { url, sessionID in
                guard url.lastPathComponent == "opencode.db" else {
                    return OpenCodeSessionParser.parseFileFull(at: url)
                }
                return OpenCodeSqliteReader.loadFullSession(customRoot: url.path, sessionID: sessionID)
            },
            searchUsesIdentityAtURL: { $0.lastPathComponent == "opencode.db" },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
                    let discovery = OpenCodeSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        let base = url.deletingPathExtension().lastPathComponent
                        if base.isEmpty { continue }
                        map[base] = url
                        if base.hasPrefix("ses_") {
                            map[String(base.dropFirst("ses_".count))] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    OpenCodeSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .opencode, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "OpenCode",
            otherAgentPill: PillSpec(color: .purple, shortcut: "4")
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for opencode (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let opencode = SessionSourceAdapter(
        descriptor: .opencode,
        makeRuntime: {
            let indexer = OpenCodeSessionIndexer()
            return SourceRuntime(
                source: .opencode,
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
                    refresh: { _, _, _ in
                        // SPEC §8.6: OpenCode's refresh takes no arguments; the unified
                        // indexer has always dropped mode/trigger/profile for this source.
                        indexer.refresh()
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: OpenCodeSessionIndexer.ReloadReason
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
                        if url.lastPathComponent == "opencode.db", !forcedID.isEmpty {
                            let customRoot = indexer.sessionsRootOverride.isEmpty ? nil : indexer.sessionsRootOverride
                            return OpenCodeSqliteReader.loadFullSession(customRoot: customRoot, sessionID: forcedID)
                        }
                        return OpenCodeSessionParser.parseFileFull(at: url)
                    }
                )
            )
        }
    )
}
