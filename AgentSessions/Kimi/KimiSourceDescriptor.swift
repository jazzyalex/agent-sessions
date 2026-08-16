import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let kimi: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("kimi")
        }
        return SessionSourceDescriptor(
            source: .kimi,
            shortLabel: "Kimi Code",
            badgeInitials: "KM",
            // Indigo-violet accent, distinct from Codex's blue and OpenCode's purple.
            brandHue: .calibrated(red: 0.46, green: 0.34, blue: 0.82),
            monochromeWhite: 0.66,
            onboardingAccent: { _ in Color.agentKimi },
            enablementKey: PreferencesKey.Agents.kimiEnabled,
            cliAvailableKey: PreferencesKey.kimiCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.kimiSessionsRootOverride],
            includeKey: PreferencesKey.Include.kimi,
            binaryNames: ["kimi"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.kimiSessionsRootOverride)
                let root = KimiSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in KimiSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.kimiSessionsRootOverride)
                    let discovery = KimiSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = KimiSessionDiscovery.sessionID(forWireFile: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    KimiSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .kimi, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Kimi Code",
            // K10: ⌘1–⌘9 fully allocated (Codex=1, Claude=2, … Pi=9), so Kimi has none.
            otherAgentPill: PillSpec(color: Color.agentKimi, shortcut: nil)
        )
    }()
}
