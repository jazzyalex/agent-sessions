## Findings

Review target: `agent-sessions` at commit `9e71cf125fc0521e285ff4fec9d28ba4b48465ca`.

Repo MCP confirmed the requested task, read-only review policy, `commit_pinned` assurance, and matching base and head commits. The empty diff is intentional. The findings below concern the implementation plan, not an existing code change.

### P1 — Blocking

1\. The proposed group can be clipped in the floating window despite being inside the measured region.

Evidence:

- `AgentCockpitHUDView.swift:4095–4162` — the panel measures its entire content with `LimitsContentHeightKey`. Adding the group inside this `Group` is the correct placement.
- `AgentCockpitHUDView.swift:987–989, 1024–1031` — the measurement reaches the floating-window configurator.
- `AgentCockpitHUDWindow.swift:121–125, 194–205, 337–347` — the configurator caps measured content height at 9 × 30 = 270 points, then fixes the window's minimum and maximum size to the resulting height.
- `AgentCockpitHUDView.swift:1042` — the window content is clipped to its rounded boundary.

The plan accounts for measurement but not for the height cap. Existing Codex/Claude runway rows plus the proposed OpenCode header and session rows can exceed 270 points. Because OpenCode is appended last, its rows are particularly vulnerable.

Required plan edit: Add an explicit overflow strategy that preserves access to all group content without silently clipping it. Specify how the floating window will scroll or resize, how its existing resize-anchor behavior is preserved, and how both surfaces will be verified. A larger fixed cap alone is not a complete solution for variable-length content.

If the solution changes `AgentCockpitHUDWindow.swift` or introduces a new layout pattern, the implementation prompt requires owner approval before coding. The current plan does not request that approval.

### P2 — Should fix before implementation

2\. The probe-filter claim and proposed test are wrong.

Evidence: `AgentCockpitHUDView.swift:1846–1853` applies `CodexProbeConfig.isProbeWorkingDirectory` and `ClaudeProbeConfig.isProbeWorkingDirectory` to every supported presence, without checking its source. The equivalent live-summary filter behaves the same way at `1706–1717`.

An OpenCode presence inside either recognized probe directory is filtered when `showProbePresences` is false. The plan incorrectly says OpenCode is unaffected and proposes a regression test that would enforce this false behavior.

Edit: Replace that claim with the source-independent rule. Test the same OpenCode presence with `showProbePresences: false` (excluded) and `true` (eligible for the subsequent resolution rules). Do not change the existing filter just to make the mistaken test pass.

3\. The plan overstates OpenCode's default-enabled behavior and understates the cost of its new published signal.

Evidence:

- `OpenCodeSourceDescriptor.swift:37–56` specifies `.always` as the fallback default.
- `AgentEnablement.swift:71–82` honors an explicitly stored preference first.
- `AgentEnablement.swift:171–226` seeds actual enablement preferences from availability, potentially writing `AgentEnabledOpenCode = false` on a machine without OpenCode.
- `AgentCockpitHUDView.swift:383–389, 436–446` already receives indexed sessions and guards incoming updates with a content fingerprint.
- `AgentCockpitHUDView.swift:397–409` explicitly documents the cost of unnecessary HUD rebuilds.

The default is not equivalent to “every user without OpenCode has OpenCode enabled.” Also, assigning an unchanged value to a new `@Published` Boolean still emits an update.

Edit: Describe `.always` as the fallback when the preference is absent, not as a guarantee about the stored value. Keep the indexed-history signal if desired, but publish only on a Boolean transition:

```
let hasHistory = !sessions.isEmpty
if hasIndexedOpenCodeSessions != hasHistory {
    hasIndexedOpenCodeSessions = hasHistory
}
```

Computing `.isEmpty` on the retained array is constant-time and requires no new filesystem access. The existing indexer publication and fingerprint work still occur; the new flag should not add a redundant view invalidation.

4\. The extra working-first sort contradicts the plan's promise to preserve HUD display ordering.

Evidence: `AgentCockpitHUDView.swift:1484–1508` constructs `rowsForDisplay` using retained display order. At `1514–1564`, hidden-window membership and priority churn are deliberately handled without immediately reordering the rows. The snapshot itself already sorts by activity priority at `1940–1953`.

The proposed `OpenCodeHUDGroup.make` performs another working-first stable partition. That can change the ordering chosen by `rowsForDisplay`, particularly while the window is hidden or during transitions.

Edit: Filter OpenCode rows from `rowsForDisplay`, preserve their incoming order, and derive the header total, visible prefix, and overflow from that single array. Remove the second partition unless the owner explicitly chooses a different ordering policy.

The counting design itself is sound: six eligible rows can produce a header count of six, four detailed rows, and a `+2 more` row. The overflow represents undisplayed detail rows; it is not a second session count.

5\. The retained tests do not yet prove the proposed UI behavior or all resolution cases.

Evidence:

- `AgentCockpitHUDView.swift:1792–1802` — `makeRowsSnapshot` currently needs a `CodexActiveSessionsModel`, indexed-session arrays, lookup indexes, and presence fixtures.
- `CodexActiveSessionsModel.swift:339–342, 395–403, 425–437` — construction is safe under the test host, and `debugApply` can inject a synthetic presence snapshot.
- `CodexActiveSessionsRegistryTests.swift:3129–3162` — the existing `makeHUDRow` fixture hardcodes Codex, so it cannot directly supply OpenCode rows.
- `AgentCockpitHUDView.swift:2334–2359` — unresolved `subagent` presences are suppressed even if they carry a session ID. The plan omits that special case.
- `AgentCockpitHUDView.swift:1857–1894` — a workspace match can resolve a presence before the unresolved-placeholder predicate runs.

Edit: Specify an OpenCode-specific `HUDRow` fixture and deterministic `PresenceSnapshot` injection, including explicit live-state maps for working versus idle. Distinguish a synthetic headless mapper test from a real process-discovery test. Add retained tests for unresolved subagents, session-ID-only and focusable unresolved presences, non-iTerm TTY-only presences, and competing workspace matches.

Also add retained integration coverage for the OpenCode-only panel branch, detection-off behavior, and toggling `AgentEnabledOpenCode` while the existing snapshot remains unchanged. Pure-model tests cannot establish that either mounted SwiftUI surface responds immediately or that its new height is handled correctly. The proposed temporary PNG test is useful but does not replace those regressions.

6\. Localization verification is underspecified, especially plural rendering and longer translations.

Evidence: `docs/localization.md:27–54, 74–90` distinguishes direct SwiftUI literals, reusable localized resources, verbatim data, and plural variants. It also requires verification across counts and long localized text.

The plan proposes the right mechanisms, but its retained tests do not assert the rendered localized count strings. Its catalog verification also needs to specify both catalogs, rather than leaving the compilation scope ambiguous.

Edit: Use `Text(verbatim:)` for session titles and provider names, and catalog-backed plural strings for the count and overflow. Add assertions for 0, 1, 2, and 6 in English and Simplified Chinese, plus a long-text rendering case. Update `Localizable.xcstrings` for the new UI strings; validate and compile both `Localizable.xcstrings` and `InfoPlist.xcstrings`. No unrelated Info.plist strings need to be added.

7\. The implementation preflight and approval boundary are missing.

Evidence: `agents.md:7, 123–129` requires reading the current handover and preserving shared working-tree state. The task prompt additionally requires checking `git status` before edits, forbids touching another person's uncommitted work, and requires approval for changes outside the HUD view and tests.

The plan includes a resource catalog edit outside that narrow file scope, and the necessary overflow correction may require a separate window file or new layout pattern.

Edit: Add a first implementation step: read the latest handover, inspect `git status`, identify any overlapping dirty files, and request the specified approval for the localization resource and any wider layout changes. Do not interpret this plan review as implementation authorization.

### P3 — Minor corrections

8\. The provider chooser's heading is misleading once OpenCode becomes visible.

Evidence: `AgentCockpitHUDView.swift:4500–4525` labels the chooser “Agents shown”, but its explanatory copy limits it to usage sections. OpenCode will appear in the panel without appearing in that chooser.

Edit: Prefer “Usage sections shown”, retaining the existing explanatory text. Keep OpenCode enablement in the agent preference, not `QuotaMeterProvider`.

9\. Avoid coupling the new session-list cap to runway internals.

Evidence: `AgentCockpitHUDView.swift:4900–4910` defines `HUDRunwayLayout.maxDetailRows` specifically as a budget for burn attribution.

Edit: Give `OpenCodeHUDGroup` its own `maxVisibleSessions = 4` constant. Reuse runway text metrics and separators, not its consumption-row budget. This preserves the intended separation between session presence and runway features.

## Answers to the three open questions

1\. Is indexed OpenCode history the right empty-group visibility signal?

Yes, with qualifications. Prefer it over hiding whenever there are zero live rows.

Hiding all empty groups makes the required “No detected running sessions” state effectively unreachable. Indexed history provides a useful, already-cached indication of prior OpenCode use without introducing an availability probe or filesystem scan.

However, history is not proof that OpenCode is currently installed. It can persist after removal, and a fresh OpenCode installation without indexed sessions may not yet show the group. Those are acceptable tradeoffs if documented accurately. Publish the Boolean only when its value changes.

2\. Should the OpenCode-only state show the group alone?

Yes. When all quota sections are hidden or unavailable but the OpenCode group qualifies for display, render the OpenCode group without “Usage tracking is off.”

That message concerns usage tracking, which is not a prerequisite for displaying detected OpenCode sessions.

When global live detection is disabled, hide the OpenCode group and retain the existing detection-disabled callout. Existing Codex/Claude quota sections may still render independently.

3\. Is widening `makeRowsSnapshot` and `HUDRowsSnapshot` acceptable?

Yes. Changing both from their current restricted visibility to `internal` is a reasonable, narrow testability adjustment.

`CodexActiveSessionsModel()` is safe to construct under the test host because its initializer skips the background stream there (`CodexActiveSessionsModel.swift:339–342`). The existing `debugApply` seam can provide deterministic snapshot state (`395–403`). `AgentCockpitHUDView.buildSessionLookupIndexes` is also accessible for fixtures (`AgentCockpitHUDView.swift:2524–2532`).

Mark relevant tests `@MainActor`, create OpenCode-specific fixtures, and seed the model's live-state map rather than relying on filesystem modification times. No production poller or real user session is needed for these tests.

## Required plan edits

The following are the substantive replacements I would give the implementing agent.

Replace the probe-rule paragraph:

> Probe exclusion is source-independent. When `showProbePresences` is false, a candidate from any supported source, including OpenCode, is excluded if its workspace matches a recognized Codex or Claude probe directory. The OpenCode group applies no additional exclusion rule.

Replace the count and ordering decision:

> Build the group from `displayState.rowsForDisplay`. Filter to `.opencode`, remove repeated `HUDRow.id` values while keeping the first occurrence, and preserve the resulting order. Let `totalCount` equal that array's count. Render its first four rows and a localized overflow summary for the remainder. Never obtain the header count from `liveSessionSummary`, indexed history, or a separately filtered collection.

Replace the visibility and signal decision:

> Show the OpenCode group only when live detection and `AgentEnabledOpenCode` are enabled, and either eligible OpenCode rows exist or the cached indexer contains historical OpenCode sessions. The history signal is informational, not an availability guarantee. Initialize it from the indexer's retained array and publish updates only when its Boolean value changes. Filtering remains after the cached snapshot, so preference changes require no rebuild-gate invalidation.

Add a mandatory layout step:

> Place the OpenCode group after the provider entries within the `HUDLimitsRowsPanel` content measured by `LimitsContentHeightKey`. Handle the floating configurator's 270-point height limit explicitly with accessible vertical overflow, using the repository's `ScrollView` guidance (`agents.md:173–176`). Preserve the fixed-width sizing and resize-anchor behavior. Test quota-only, OpenCode-only, both providers with runway expanded, 0/1/4/6 OpenCode sessions, detection disabled, and both strip and floating presentations. Obtain owner approval before any change outside the authorized file scope or any new layout pattern.

Replace the end-to-end test specification:

> Construct `CodexActiveSessionsModel()` under XCTest, supply synthetic `CodexActivePresence` instances and a `PresenceSnapshot` with explicit activity classifications through `debugApply`, build lookup indexes from OpenCode `Session` fixtures, and invoke the now-internal `makeRowsSnapshot`. Test resolved-identity deduplication, genuinely unresolved placeholders, the unresolved-subagent exception, probe filtering in both modes, headless mapper behavior, and working/idle transitions. Test the separate process-discovery eligibility rules through their existing injectable seams; do not present an injected headless presence as proof of actual process discovery. Retain a mounted-panel test for preference changes and empty-state switching.

Finally, add the localization checks and the clean-working-tree preflight from findings 6 and 7.

## Evidence limitations

This was a plan review against the pinned commit, not a build or runtime validation. I made no edits and ran no tests.

Repo MCP allowed the initial identity verification and the substantive pinned code reads. A subsequent concurrent checkout HEAD change caused the connector to reject further reads. I therefore did not independently establish the repository-wide absence of an OpenCode icon asset or inspect every auxiliary view definition. I did verify the code paths supporting the findings above. The read-only workspace was closed.

The core design—reuse the cached HUD snapshot, filter OpenCode after snapshot construction, and keep it entirely separate from quota/runway models—is appropriate. The unresolved floating-window clipping issue prevents approval of the plan as written.

VERDICT: NO-SHIP