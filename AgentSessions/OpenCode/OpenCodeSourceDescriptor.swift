import Foundation
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
                // Check opencode.db first (v1.2+ SQLite backend). This probe opens a
                // database, so it stays a call into OpenCodeBackendDetector rather than
                // going through `ctx.fileProbe` — see the task report.
                if OpenCodeBackendDetector.isSQLiteAvailable(customRoot: custom) { return true }
                let root = OpenCodeSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in OpenCodeSessionParser.parseFileFull(at: url) },
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
