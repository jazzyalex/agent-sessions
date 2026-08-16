import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let pi: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("pi")
        }
        return SessionSourceDescriptor(
            source: .pi,
            shortLabel: "Pi",
            badgeInitials: "PI",
            // Green-cyan accent, distinct from Gemini and Cursor.
            brandHue: .calibrated(red: 0.05, green: 0.62, blue: 0.48),
            monochromeWhite: 0.68,
            onboardingAccent: { _ in Color.agentPi },
            enablementKey: PreferencesKey.Agents.piEnabled,
            cliAvailableKey: PreferencesKey.piCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.piSessionsRootOverride],
            includeKey: PreferencesKey.Include.pi,
            binaryNames: ["pi"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.piSessionsRootOverride)
                let root = PiSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in PiSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.piSessionsRootOverride)
                    let discovery = PiSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = PiSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    PiSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .pi, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Pi CLI",
            otherAgentPill: PillSpec(color: Color.agentPi, shortcut: "9")
        )
    }()
}
