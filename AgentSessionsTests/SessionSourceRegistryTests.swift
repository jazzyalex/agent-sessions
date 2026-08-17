import XCTest
import AppKit
import SwiftUI
@testable import AgentSessions

/// SPEC §10.1/10.2/10.3/10.5 — the registry's structural contracts.
///
/// Every assertion here compares the registry against an *independent* source of truth:
/// the enum's own `allCases`, Task 1's frozen
/// `SourceKeyTable`, or a table written out by hand. Nothing asserts a registry value
/// against itself — which is why Task 3 replaced the palette *parity* test with pinned
/// goldens the moment `TranscriptColorSystem` started reading the registry.
@MainActor
final class SessionSourceRegistryTests: XCTestCase {

    // MARK: - Order + bijection (SPEC §10.1)

    func testRegistryOrderEqualsSessionSourceAllCases() {
        XCTAssertEqual(SessionSourceRegistry.ordered.map(\.descriptor.source), SessionSource.allCases)
    }

    func testRegistryLookupsCoverEverySource() {
        XCTAssertEqual(Set(SessionSourceRegistry.bySource.keys), Set(SessionSource.allCases))
        for source in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.adapter(for: source).descriptor.source, source, "\(source)")
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: source).source, source, "\(source)")
            XCTAssertEqual(source.descriptor.source, source, "\(source)")
        }
    }

    // MARK: - Keys (SPEC §10.2)

    func testDescriptorKeysMatchTheStabilityTable() {
        for s in SessionSource.allCases {
            let d = SessionSourceRegistry.descriptor(for: s)
            guard let expected = SourceKeyTable.row(for: s) else {
                XCTFail("missing frozen key row for \(s)")
                continue
            }
            XCTAssertEqual(d.enablementKey, expected.enablement, "\(s)")
            XCTAssertEqual(d.cliAvailableKey, expected.cliAvailable, "\(s)")
            XCTAssertEqual(d.rootOverrideKeys, expected.rootOverrides, "\(s)")
            XCTAssertEqual(d.includeKey, expected.include, "\(s)")
        }
        XCTAssertNil(SessionSourceRegistry.descriptor(for: .openclaw).cliAvailableKey)          // K4
        XCTAssertEqual(SessionSourceRegistry.descriptor(for: .droid).rootOverrideKeys,
                       [PreferencesKey.Paths.droidSessionsRootOverride,
                        PreferencesKey.Paths.droidProjectsRootOverride])                        // K3
    }

    /// Every source except droid carries exactly one root-override key, and openclaw is
    /// the only source with no CLI-availability key at all (K3/K4 stated as a shape, not
    /// re-listed per source — the strings themselves are frozen in
    /// `SessionSourceKeyStabilityTests`).
    func testRootOverrideAndCLIKeyShapes() {
        for s in SessionSource.allCases {
            let d = SessionSourceRegistry.descriptor(for: s)
            XCTAssertEqual(d.rootOverrideKeys.count, s == .droid ? 2 : 1, "\(s)")
            XCTAssertEqual(d.cliAvailableKey == nil, s == .openclaw, "\(s)")
        }
    }

    func testAvailabilityUsesInjectedFilesystemAndHomeDirectory() {
        let suiteName = "SessionSourceRegistryTests-Availability-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)

        let emptyContext = AvailabilityContext(defaults: defaults,
                                               fileProbe: FakeFileProbe(),
                                               homeDirectory: home,
                                               detectBinary: { _ in false })
        XCTAssertFalse(SessionSource.claude.descriptor.isAvailable(emptyContext),
                       "Claude availability must not read the developer's real home")
        XCTAssertFalse(SessionSource.opencode.descriptor.isAvailable(emptyContext),
                       "OpenCode availability must not read the developer's real home")
        XCTAssertFalse(SessionSource.hermes.descriptor.isAvailable(emptyContext),
                       "Hermes availability must not read the developer's real home")

        let claudeProbe = FakeFileProbe(directories: [
            "/virtual/home/.claude",
            "/virtual/home/.claude/projects"
        ])
        let claudeContext = AvailabilityContext(defaults: defaults,
                                                fileProbe: claudeProbe,
                                                homeDirectory: home,
                                                detectBinary: { _ in false })
        XCTAssertTrue(SessionSource.claude.descriptor.isAvailable(claudeContext))

        defaults.set("/virtual/opencode.db", forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
        let openCodeProbe = FakeFileProbe(sqliteTablesByPath: [
            "/virtual/opencode.db": ["session"]
        ])
        let openCodeContext = AvailabilityContext(defaults: defaults,
                                                  fileProbe: openCodeProbe,
                                                  homeDirectory: home,
                                                  detectBinary: { _ in false })
        XCTAssertTrue(SessionSource.opencode.descriptor.isAvailable(openCodeContext))

        defaults.removeObject(forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
        let hermesProbe = FakeFileProbe(directories: [
            "/virtual/home/.hermes",
            "/virtual/home/.hermes/sessions"
        ])
        let hermesContext = AvailabilityContext(defaults: defaults,
                                                fileProbe: hermesProbe,
                                                homeDirectory: home,
                                                detectBinary: { _ in false })
        XCTAssertTrue(SessionSource.hermes.descriptor.isAvailable(hermesContext))

        let stateDBOnlyProbe = FakeFileProbe(files: [
            "/virtual/home/.hermes/state.db"
        ])
        let stateDBOnlyContext = AvailabilityContext(defaults: defaults,
                                                     fileProbe: stateDBOnlyProbe,
                                                     homeDirectory: home,
                                                     detectBinary: { _ in false })
        XCTAssertFalse(SessionSource.hermes.descriptor.isAvailable(stateDBOnlyContext),
                       "state.db alone was not a pre-registry Hermes enablement signal")
    }

    func testInjectedHomeExpansionPreservesNamedUserPaths() {
        let injectedHome = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        XCTAssertEqual(UserPathExpansion.expand("~/sessions", relativeTo: injectedHome),
                       "/virtual/home/sessions")

        let namedUserPath = "~\(NSUserName())/sessions"
        XCTAssertEqual(UserPathExpansion.expand(namedUserPath, relativeTo: injectedHome),
                       (namedUserPath as NSString).expandingTildeInPath,
                       "named-user roots must retain the pre-injection Foundation behavior")
    }

    func testHermesDiscoveryUsesInjectedFilesystemAndHomeDirectory() {
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        let probe = FakeFileProbe(
            files: [
                "/virtual/home/.hermes/state.db",
                "/virtual/home/.hermes/sessions/session_virtual.json"
            ],
            directories: [
                "/virtual/home/.hermes",
                "/virtual/home/.hermes/sessions"
            ]
        )
        let discovery = HermesSessionDiscovery(fileProbe: probe, homeDirectory: home)

        XCTAssertEqual(discovery.sessionsRoot().path, "/virtual/home/.hermes/sessions")
        XCTAssertEqual(discovery.stateDBURL().path, "/virtual/home/.hermes/state.db")
        XCTAssertTrue(discovery.hasStateDB())
        XCTAssertEqual(discovery.discoverSessionFiles().map(\.lastPathComponent),
                       ["session_virtual.json"])
    }

    // MARK: - Palette + label goldens (SPEC §10.3)
    //
    // Task 2 guarded the palette with a *parity* test (registry vs. the live switch).
    // Task 3 pointed those switches at the registry, which makes parity circular — a
    // test that compares the registry to itself proves nothing. So the switches' output
    // was recorded one last time while they were still live (2026-08-15, both
    // appearances, sRGB components) and pinned here as hand-written literals.
    //
    // These tables are the independent side of the comparison. NEVER regenerate them
    // from the registry, the descriptors, or `TranscriptColorSystem`: a golden computed
    // from the thing it guards is not a golden. Changing a brand hue is a deliberate
    // product decision, and updating the literal by hand is exactly the friction that
    // makes it deliberate.
    //
    // `adaptiveBrand` hands back a *dynamic* NSColor, so the comparison is always
    // "what does it draw under this appearance", never object equality.

    /// `TranscriptColorSystem.agentBrandAccent(source:)` as it drew before the flip.
    private static let brandAccentGoldens: [SessionSource: (aqua: [CGFloat], darkAqua: [CGFloat])] = [
        .codex: (aqua: [0.180158, 0.384268, 0.665022, 1.000000], darkAqua: [0.265213, 0.465081, 0.740000, 1.000000]),
        .claude: (aqua: [0.791664, 0.534844, 0.281364, 1.000000], darkAqua: [0.791664, 0.565662, 0.342600, 1.000000]),
        .antigravity: (aqua: [0.349020, 0.678431, 0.768627, 1.000000], darkAqua: [0.415686, 0.768627, 0.862745, 1.000000]),
        .opencode: (aqua: [0.686275, 0.321569, 0.870588, 1.000000], darkAqua: [0.749020, 0.352941, 0.949020, 1.000000]),
        .hermes: (aqua: [0.681296, 0.690266, 0.233215, 1.000000], darkAqua: [0.731538, 0.740000, 0.308816, 1.000000]),
        .copilot: (aqua: [0.929563, 0.315907, 0.664030, 1.000000], darkAqua: [0.929563, 0.389546, 0.695894, 1.000000]),
        .droid: (aqua: [0.170852, 0.720353, 0.350321, 1.000000], darkAqua: [0.243251, 0.740000, 0.405491, 1.000000]),
        .openclaw: (aqua: [0.911803, 0.418328, 0.257114, 1.000000], darkAqua: [0.911803, 0.477545, 0.335677, 1.000000]),
        .cursor: (aqua: [0.239265, 0.662337, 0.753023, 1.000000], darkAqua: [0.300916, 0.673220, 0.753023, 1.000000]),
        .pi: (aqua: [0.000000, 0.672455, 0.553618, 1.000000], darkAqua: [0.088800, 0.740000, 0.624919, 1.000000]),
        .kimi: (aqua: [0.537587, 0.441176, 0.854966, 1.000000], darkAqua: [0.575672, 0.490830, 0.854966, 1.000000]),
        .grok: (aqua: [0.423895, 0.479055, 0.591420, 1.000000], darkAqua: [0.555542, 0.616276, 0.740000, 1.000000]),
        .qwen: (aqua: [0.528275, 0.410185, 0.813014, 1.000000], darkAqua: [0.562444, 0.458524, 0.813014, 1.000000])
    ]

    /// The ten toolbar pill colors, recorded from the same pre-flip palette. These also
    /// pin what `UnifiedSessionsView.sourceAccent(_:)` now derives (`otherAgentPill?.color`
    /// with a brand-accent fallback for codex/claude): the antigravity and opencode rows
    /// are SwiftUI's `.teal`/`.purple`, which is what that switch used to return literally,
    /// and they land on `systemTeal`/`systemPurple`'s components to well within tolerance.
    private static let pillColorGoldens: [SessionSource: (aqua: [CGFloat], darkAqua: [CGFloat])] = [
        .antigravity: (aqua: [0.349020, 0.678431, 0.768627, 1.000000], darkAqua: [0.415686, 0.768627, 0.862745, 1.000000]),
        .opencode: (aqua: [0.686275, 0.321569, 0.870588, 1.000000], darkAqua: [0.749020, 0.352941, 0.949020, 1.000000]),
        .hermes: (aqua: [0.681296, 0.690266, 0.233215, 1.000000], darkAqua: [0.731538, 0.740000, 0.308816, 1.000000]),
        .copilot: (aqua: [0.929563, 0.315907, 0.664030, 1.000000], darkAqua: [0.929563, 0.389546, 0.695894, 1.000000]),
        .droid: (aqua: [0.170852, 0.720353, 0.350321, 1.000000], darkAqua: [0.243251, 0.740000, 0.405491, 1.000000]),
        .openclaw: (aqua: [0.911803, 0.418328, 0.257114, 1.000000], darkAqua: [0.911803, 0.477545, 0.335677, 1.000000]),
        .cursor: (aqua: [0.239265, 0.662337, 0.753023, 1.000000], darkAqua: [0.300916, 0.673220, 0.753023, 1.000000]),
        .pi: (aqua: [0.000000, 0.672455, 0.553618, 1.000000], darkAqua: [0.088800, 0.740000, 0.624919, 1.000000]),
        .kimi: (aqua: [0.537587, 0.441176, 0.854966, 1.000000], darkAqua: [0.575672, 0.490830, 0.854966, 1.000000]),
        .grok: (aqua: [0.423895, 0.479055, 0.591420, 1.000000], darkAqua: [0.555542, 0.616276, 0.740000, 1.000000]),
        .qwen: (aqua: [0.528275, 0.410185, 0.813014, 1.000000], darkAqua: [0.562444, 0.458524, 0.813014, 1.000000])
    ]

    /// The row/legend label the three deleted label switches produced (`SessionTerminalView`'s
    /// `agentLegendLabel` and `UnifiedSessionsView`'s two — all three were byte-identical).
    private static let shortLabelGoldens: [SessionSource: String] = [
        .codex: "Codex",
        .claude: "Claude",
        .antigravity: "Antigravity",
        .opencode: "OpenCode",
        .hermes: "Hermes",
        .copilot: "Copilot",
        .droid: "Droid",
        .openclaw: "OpenClaw",
        .cursor: "Cursor",
        .pi: "Pi",
        .kimi: "Kimi Code",
        .grok: "Grok CLI",
        .qwen: "Qwen Code"
    ]

    func testBrandAccentMatchesPinnedGoldens() {
        for s in SessionSource.allCases {
            guard let golden = Self.brandAccentGoldens[s] else {
                XCTFail("no pinned brand golden for \(s)")
                continue
            }
            let live: NSColor = TranscriptColorSystem.agentBrandAccent(source: s)
            Self.assertDraws(live, aqua: golden.aqua, darkAqua: golden.darkAqua, label: "\(s)")
            // The registry's reconstruction is what `agentBrandAccent` now returns, but
            // assert it directly too so a regression names the layer it came from.
            Self.assertDraws(SessionSourceRegistry.resolvedBrandAccent(for: s),
                             aqua: golden.aqua, darkAqua: golden.darkAqua, label: "registry \(s)")
        }
    }

    /// Brand accents must be *value-stable*, not merely correct.
    ///
    /// `adaptiveBrand` mints a fresh dynamic `NSColor` per call, and two of those never
    /// compare equal. Before the registry, consumers read memoized `Color.agentX` statics,
    /// so SwiftUI's equality checks short-circuited; `UnifiedSessionsView.cellSource(for:)`
    /// asks for a row accent twice per row per rebuild and this repo is measurably
    /// sensitive to `Table` diffing. The registry therefore resolves each accent once.
    func testResolvedBrandAccentIsValueStableAcrossCalls() {
        for s in SessionSource.allCases {
            let first = SessionSourceRegistry.resolvedBrandAccent(for: s)
            let second = SessionSourceRegistry.resolvedBrandAccent(for: s)
            XCTAssertTrue(first === second, "\(s): brand accent must be the same instance across calls")

            // The two public consumer surfaces must inherit that stability.
            let viaColorSystem: NSColor = TranscriptColorSystem.agentBrandAccent(source: s)
            XCTAssertTrue(viaColorSystem === first, "\(s): TranscriptColorSystem must hand back the memoized instance")
            XCTAssertEqual(Color.agentColor(for: s), Color.agentColor(for: s),
                           "\(s): analytics brand color must compare equal across calls")
        }
    }

    func testPersistedRawSourceStringsResolveThroughRegistryColors() {
        for source in SessionSource.allCases {
            XCTAssertEqual(Color.agentColor(for: source.rawValue),
                           Color.agentColor(for: source), "brand \(source)")
            XCTAssertEqual(Color.agentColor(for: source.rawValue, monochrome: true),
                           Color.agentColor(for: source, monochrome: true), "monochrome \(source)")
        }

        // Keep pre-enum aliases working after exact persisted values take the
        // registry path.
        XCTAssertEqual(Color.agentColor(for: "gemini"), Color.agentColor(for: .antigravity))
        XCTAssertEqual(Color.agentColor(for: "clawdbot"), Color.agentColor(for: .openclaw))
        XCTAssertEqual(Color.agentColor(for: "pi coding agent"), Color.agentColor(for: .pi))
    }

    /// Pill colors are read through a closure (that is what breaks the initialization
    /// cycle), so they are re-evaluated per read — they must still be equal every time.
    /// Hermes is the one that matters: its pill re-runs `agentBrandAccent` on each read, so
    /// it is stable only because that call is now memoized.
    func testOtherAgentPillColorsAreValueStableAcrossReads() {
        for s in SessionSource.allCases {
            guard let pill = SessionSourceRegistry.descriptor(for: s).otherAgentPill else { continue }
            XCTAssertEqual(pill.color, pill.color, "\(s): pill color must compare equal across reads")
        }
    }

    func testOtherAgentPillColorsMatchPinnedGoldens() {
        for s in SessionSource.allCases {
            let pill = SessionSourceRegistry.descriptor(for: s).otherAgentPill
            guard let golden = Self.pillColorGoldens[s] else {
                XCTAssertNil(pill, "\(s) has no pinned pill golden, so it must have no pill")
                continue
            }
            guard let pill else {
                XCTFail("\(s) should have a toolbar pill")
                continue
            }
            Self.assertDraws(NSColor(pill.color),
                             aqua: golden.aqua, darkAqua: golden.darkAqua, label: "pill \(s)")
        }
    }

    func testShortLabelsMatchPinnedGoldens() {
        for s in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).shortLabel,
                           Self.shortLabelGoldens[s], "\(s)")
        }
    }

    /// K12: the badge initials the onboarding grid draws. Two letters everywhere except
    /// droid's single "D" — pinned from `AgentBadge.initials(for:)` before it was deleted.
    func testBadgeInitialsMatchPinnedGoldens() {
        let goldens: [SessionSource: String] = [
            .codex: "CX", .claude: "CC", .antigravity: "AG", .opencode: "OC",
            .hermes: "HM", .copilot: "CP", .droid: "D", .openclaw: "CL",
            .cursor: "CR", .pi: "PI", .kimi: "KM", .grok: "GK", .qwen: "QW"
        ]
        for s in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).badgeInitials, goldens[s], "\(s)")
        }
    }

    /// The `Color(white:)` shades Analytics' monochrome mode draws, pinned from the
    /// deleted `Color.agentXGray` switch.
    func testMonochromeWhitesMatchPinnedGoldens() {
        let goldens: [SessionSource: Double] = [
            .codex: 0.4, .claude: 0.5, .antigravity: 0.6, .opencode: 0.7,
            .hermes: 0.72, .copilot: 0.75, .droid: 0.8, .openclaw: 0.85,
            .cursor: 0.9, .pi: 0.68, .kimi: 0.66, .grok: 0.62, .qwen: 0.61
        ]
        for s in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).monochromeWhite,
                           goldens[s] ?? -1, accuracy: 0.0001, "\(s)")
        }
    }

    /// K6: exactly two sources hand back an AppKit *system dynamic* color unwrapped;
    /// the other ten are light-calibrated triples that must go through `adaptiveBrand`.
    func testSystemPassthroughSourcesAreExactlyAntigravityAndOpencode() {
        var passthrough: Set<SessionSource> = []
        for s in SessionSource.allCases {
            switch SessionSourceRegistry.descriptor(for: s).brandHue {
            case .system:
                passthrough.insert(s)
            case .calibrated:
                break
            }
        }
        XCTAssertEqual(passthrough, [.antigravity, .opencode])
    }

    // MARK: - Enablement semantics (SPEC §10.5 / K7)

    func testDefaultEnablementSemanticsPreserved() {
        let alwaysOn: Set<SessionSource> = [.codex, .claude, .antigravity, .opencode, .copilot, .droid]
        for s in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).defaultEnabled,
                           alwaysOn.contains(s) ? .always : .whenAvailable, "\(s)")
        }
    }

    // MARK: - Resume gating

    func testResumeGatingMatchesLegacyBehavior() {
        for s in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).supportsResume,
                           !(s == .droid || s == .openclaw), "\(s)")
        }
        // The legacy `resumeAgentLabel` switch has no arm for droid/openclaw (they fall
        // into `default: "CLI"`, which is unreachable because they never resume), so the
        // descriptor carries nil for exactly those two.
        for s in SessionSource.allCases {
            XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).resumeAgentLabel == nil,
                           s == .droid || s == .openclaw, "\(s)")
        }
    }

    // MARK: - Toolbar pill (K10)

    /// Codex and Claude render as fixed segmented pills, never as "other agent" pills, so
    /// they carry no `PillSpec`. Shortcuts are frozen history: ⌘3–⌘9 are allocated in
    /// toolbar order and hermes/kimi/grok get none because the range is exhausted.
    func testOtherAgentPillsMatchTheFrozenToolbarTable() {
        let expectedShortcuts: [SessionSource: String?] = [
            .antigravity: "3",
            .opencode: "4",
            .hermes: nil,
            .copilot: "5",
            .droid: "6",
            .openclaw: "7",
            .cursor: "8",
            .pi: "9",
            .kimi: nil,
            .grok: nil,
            .qwen: nil
        ]
        XCTAssertEqual(Set(expectedShortcuts.keys),
                       Set(SessionSource.allCases.filter { $0 != .codex && $0 != .claude }),
                       "shortcut golden must name every other-agent pill explicitly")
        for s in SessionSource.allCases {
            let pill = SessionSourceRegistry.descriptor(for: s).otherAgentPill
            if s == .codex || s == .claude {
                XCTAssertNil(pill, "\(s)")
                continue
            }
            guard let pill else {
                XCTFail("\(s) should have a toolbar pill")
                continue
            }
            XCTAssertEqual(pill.shortcut, expectedShortcuts[s] ?? nil, "\(s)")
        }
    }

    // MARK: - Capabilities present where the legacy switches had arms

    /// Every source must expose at least one full-parse route. Current sources also retain
    /// archive support, while a future DB-only source may legitimately decline it.
    func testEveryCurrentSourceSuppliesParsingAndArchiving() {
        let sourcesWithFrozenArchiveSupport: Set<SessionSource> = [
            .codex, .claude, .antigravity, .opencode, .hermes, .copilot,
            .droid, .openclaw, .cursor, .pi, .kimi, .grok, .qwen
        ]
        for s in SessionSource.allCases {
            let d = SessionSourceRegistry.descriptor(for: s)
            XCTAssertTrue(d.parseFullByPath != nil || d.parseFullByIdentity != nil, "\(s)")
            XCTAssertEqual(d.parseFullByIdentity != nil,
                           d.searchUsesIdentityAtURL != nil,
                           "\(s) must configure identity parsing and URL selection together")
            if sourcesWithFrozenArchiveSupport.contains(s) {
                XCTAssertNotNil(d.archive, "\(s)")
            }
            XCTAssertFalse(d.binaryNames.isEmpty, "\(s)")
        }
        XCTAssertNotNil(SessionSource.opencode.descriptor.parseFullByIdentity)
        XCTAssertNotNil(SessionSource.hermes.descriptor.parseFullByIdentity)
        XCTAssertTrue(SessionSource.opencode.descriptor.searchUsesIdentityAtURL?(
            URL(fileURLWithPath: "/tmp/opencode.db")) == true)
        XCTAssertTrue(SessionSource.hermes.descriptor.searchUsesIdentityAtURL?(
            URL(fileURLWithPath: "/tmp/state.db")) == true)
        XCTAssertFalse(SessionSource.hermes.descriptor.searchUsesIdentityAtURL?(
            URL(fileURLWithPath: "/tmp/session.json")) == true)
    }

    // MARK: - Helpers

    /// Asserts a (possibly dynamic) color draws the pinned sRGB components in both
    /// appearances.
    private static func assertDraws(_ color: NSColor,
                                    aqua: [CGFloat],
                                    darkAqua: [CGFloat],
                                    label: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        for (appearanceName, expected) in [(NSAppearance.Name.aqua, aqua), (.darkAqua, darkAqua)] {
            let actual = resolvedComponents(color, appearance: appearanceName)
            guard actual.count == 4 else {
                XCTFail("\(label) \(appearanceName.rawValue): could not resolve components",
                        file: file, line: line)
                continue
            }
            // Guard the golden side too: `zip` truncates to the shorter sequence, so a
            // short literal row would silently assert on fewer than four components.
            guard expected.count == 4 else {
                XCTFail("\(label) \(appearanceName.rawValue): golden must have 4 components, has \(expected.count)",
                        file: file, line: line)
                continue
            }
            for (index, pair) in zip(actual, expected).enumerated() {
                XCTAssertEqual(pair.0, pair.1, accuracy: 0.0001,
                               "\(label) \(appearanceName.rawValue) component \(index)",
                               file: file, line: line)
            }
        }
    }

    /// Resolves a (possibly dynamic) NSColor under a named appearance and returns its
    /// sRGB components. Must run on the main thread — hence the `@MainActor` class.
    private static func resolvedComponents(_ color: NSColor,
                                           appearance name: NSAppearance.Name) -> [CGFloat] {
        guard let appearance = NSAppearance(named: name) else { return [] }
        var out: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            guard let resolved = color.usingColorSpace(.sRGB) else { return }
            out = [resolved.redComponent,
                   resolved.greenComponent,
                   resolved.blueComponent,
                   resolved.alphaComponent]
        }
        return out
    }
}
