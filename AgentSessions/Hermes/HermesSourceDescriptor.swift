import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let hermes: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("hermes")
        }
        return SessionSourceDescriptor(
            source: .hermes,
            shortLabel: "Hermes",
            badgeInitials: "HM",
            // Olive-gold accent, shifted away from Claude/OpenClaw warm oranges.
            brandHue: .calibrated(red: 0.62, green: 0.64, blue: 0.18),
            monochromeWhite: 0.72,
            onboardingAccent: { _ in Color.agentHermes },
            enablementKey: PreferencesKey.Agents.hermesEnabled,
            cliAvailableKey: PreferencesKey.hermesCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.hermesSessionsRootOverride],
            includeKey: PreferencesKey.Include.hermes,
            binaryNames: ["hermes"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.hermesSessionsRootOverride)
                let root = HermesSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in HermesSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.hermesSessionsRootOverride)
                    let discovery = HermesSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = HermesSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    HermesSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .hermes, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Hermes",
            // K10: ⌘3–⌘9 were already allocated when Hermes shipped, so it has no shortcut.
            otherAgentPill: PillSpec(color: TranscriptColorSystem.agentBrandAccent(source: .hermes),
                                     shortcut: nil)
        )
    }()
}
