import XCTest
import SwiftUI
@testable import AgentSessions

/// Task 8 — the view layer's registry derivations (SPEC §6).
///
/// `SessionSourceRegistryTests` pins what each descriptor *contains* (pill colors, short
/// labels, resume labels). This file pins what the views *derive from* those descriptors:
/// the toolbar-pill sequence, and the source ↔ Preferences-pane mapping. Both were
/// hand-written per-source lists before this task, and both had already drifted at least
/// once — which is the whole reason they are asserted here rather than trusted.
@MainActor
final class ViewRegistryDerivationTests: XCTestCase {

    // MARK: - Toolbar pills

    /// `UnifiedSessionsView.enabledOtherAgentSpecs` walks `SessionSourceRegistry.ordered`
    /// and keeps the entries that carry a `PillSpec`. That order must equal the registry's,
    /// because the registry's order is the frozen toolbar order.
    func testRegistryOrderMatchesSessionSourceAllCases() {
        XCTAssertEqual(SessionSourceRegistry.ordered.map(\.descriptor.source),
                       SessionSource.allCases)
    }

    /// Every source except Codex and Claude renders as an "other agent" pill, so every
    /// source except those two must carry a `PillSpec` — otherwise the compactMap silently
    /// drops it from the toolbar.
    func testEverySourceExceptCodexAndClaudeCarriesAPillSpec() {
        let withPill = SessionSourceRegistry.ordered
            .filter { $0.descriptor.otherAgentPill != nil }
            .map(\.descriptor.source)
        XCTAssertEqual(withPill, SessionSource.allCases.filter { $0 != .codex && $0 != .claude })
    }

    /// The derived pill sequence, in full: order preserved, Hermes/Kimi/Grok/Qwen shortcut-less
    /// because ⌘3–⌘9 ran out, Antigravity first at ⌘3.
    func testDerivedPillSequenceMatchesTheFrozenToolbar() {
        let derived: [(SessionSource, String, String?)] = SessionSourceRegistry.ordered
            .compactMap { adapter in
                guard let pill = adapter.descriptor.otherAgentPill else { return nil }
                return (adapter.descriptor.source, adapter.descriptor.shortLabel, pill.shortcut)
            }

        let expected: [(SessionSource, String, String?)] = [
            (.antigravity, "Antigravity", "3"),
            (.opencode, "OpenCode", "4"),
            (.hermes, "Hermes", nil),
            (.copilot, "Copilot", "5"),
            (.droid, "Droid", "6"),
            (.openclaw, "OpenClaw", "7"),
            (.cursor, "Cursor", "8"),
            (.pi, "Pi", "9"),
            (.kimi, "Kimi Code", nil),
            (.grok, "Grok CLI", nil),
            (.qwen, "Qwen Code", nil),
            (.devin, "Devin CLI", nil),
            (.fx, "fx", nil)
        ]

        XCTAssertEqual(derived.count, expected.count)
        for (actual, want) in zip(derived, expected) {
            XCTAssertEqual(actual.0, want.0)
            XCTAssertEqual(actual.1, want.1, "\(want.0) title")
            XCTAssertEqual(actual.2, want.2, "\(want.0) shortcut")
        }
    }

    /// Each pill shortcut must be a single character — the toolbar turns it into a
    /// `KeyEquivalent` by taking `first`, so a longer string would silently truncate.
    func testPillShortcutsAreSingleCharacters() {
        for adapter in SessionSourceRegistry.ordered {
            guard let shortcut = adapter.descriptor.otherAgentPill?.shortcut else { continue }
            XCTAssertEqual(shortcut.count, 1, "\(adapter.descriptor.source): \(shortcut)")
        }
    }

    // MARK: - Resume gating

    /// The label the Resume menu item shows. `?? "CLI"` is the old switch's `default:` and
    /// stays reachable for the two label-less sources.
    func testResumeAgentLabelFallbackCoversTheLabelLessSources() {
        for source in SessionSource.allCases {
            let descriptor = SessionSourceRegistry.descriptor(for: source)
            XCTAssertEqual(descriptor.resumeAgentLabel == nil, !descriptor.supportsResume,
                           "\(source): a source has a resume label exactly when it resumes")
        }
        XCTAssertNil(SessionSourceRegistry.descriptor(for: .droid).resumeAgentLabel)
        XCTAssertNil(SessionSourceRegistry.descriptor(for: .openclaw).resumeAgentLabel)
    }

    // MARK: - Preferences panes (K13)

    func testEverySourceMapsToADistinctPreferencesTab() {
        let tabs = SessionSource.allCases.map(PreferencesTab.init(source:))
        XCTAssertEqual(Set(tabs).count, SessionSource.allCases.count,
                       "two sources share a Preferences pane")
    }

    func testPreferencesTabSourceRoundTrips() {
        for source in SessionSource.allCases {
            XCTAssertEqual(PreferencesTab(source: source).configuredSource, source, "\(source)")
        }
        for tab in PreferencesTab.allCases {
            guard let source = tab.configuredSource else { continue }
            XCTAssertEqual(PreferencesTab(source: source), tab, "\(tab)")
        }
    }

    /// The app-wide panes must claim no source, or the sidebar's
    /// `configuredSource == nil` filter would drop them.
    func testAppWidePanesClaimNoSource() {
        for tab in [PreferencesTab.general, .agentCockpit, .unified, .usageTracking,
                    .limitAlerts, .usageProbes, .menuBar, .advanced, .about] {
            XCTAssertNil(tab.configuredSource, "\(tab)")
        }
    }

    /// §8.7: the sidebar lists every source's pane except Droid's, which is deliberately
    /// hidden. Membership is the assertion; the *order* is frozen history and stays a
    /// literal.
    func testSidebarAgentSourcesAreEveryRegistrySourceExceptTheHiddenOnes() {
        XCTAssertEqual(Set(PreferencesTab.sidebarAgentSources),
                       Set(SessionSource.allCases).subtracting(PreferencesTab.sidebarHiddenSources))
        XCTAssertEqual(PreferencesTab.sidebarAgentSources.count,
                       Set(PreferencesTab.sidebarAgentSources).count,
                       "a source is listed twice in the sidebar")
        XCTAssertEqual(PreferencesTab.sidebarHiddenSources, [.droid])
        XCTAssertFalse(PreferencesTab.sidebarAgentTabs.contains(.droidCLI))
    }

    /// The frozen sidebar order, spelled out — this is what the owner sees, and it is not
    /// registry order.
    func testSidebarAgentTabOrderIsFrozen() {
        XCTAssertEqual(PreferencesTab.sidebarAgentTabs,
                       [.codexCLI, .claudeResume, .opencode, .antigravityCLI, .copilotCLI,
                        .cursor, .pi, .kimi, .grok, .qwen, .devin, .hermesCLI, .openClawCLI, .fx])
    }

    /// Every pane a source maps to must have a non-empty title and icon: the sidebar rows
    /// are built from them.
    func testEverySourcePaneHasTitleAndIcon() {
        for source in SessionSource.allCases {
            let tab = PreferencesTab(source: source)
            XCTAssertFalse(tab.title.isEmpty, "\(source)")
            XCTAssertFalse(tab.iconName.isEmpty, "\(source)")
        }
    }
}
