import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let grok: SessionSourceDescriptor = {
        // Homebrew also ships an unrelated `grok` formula (jordansissel/grok, a regex
        // utility), so a bare PATH hit is not evidence of the Grok CLI. Require the CLI's
        // own home directory alongside the binary — injected, never `FileManager.default`.
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            guard ctx.detectBinary("grok") else { return false }
            let grokHome = ctx.homeDirectory.appendingPathComponent(".grok", isDirectory: true)
            return ctx.directoryExists(grokHome)
        }
        return SessionSourceDescriptor(
            source: .grok,
            shortLabel: "Grok CLI",
            badgeInitials: "GK",
            // Slate blue-grey, echoing xAI's monochrome mark while staying clear of
            // Codex's deep blue and Cursor's teal.
            brandHue: .calibrated(red: 0.35, green: 0.40, blue: 0.52),
            monochromeWhite: 0.62,
            onboardingAccent: { _ in Color.agentGrok },
            enablementKey: PreferencesKey.Agents.grokEnabled,
            cliAvailableKey: PreferencesKey.grokCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.grokSessionsRootOverride],
            includeKey: PreferencesKey.Include.grok,
            binaryNames: ["grok"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.grokSessionsRootOverride)
                let root = GrokSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in GrokSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.grokSessionsRootOverride)
                    let discovery = GrokSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = GrokSessionDiscovery.sessionID(forTranscript: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    GrokSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .grok, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Grok CLI",
            // K10: same exhausted ⌘-range as Hermes/Kimi.
            otherAgentPill: PillSpec(color: Color.agentGrok, shortcut: nil)
        )
    }()
}
