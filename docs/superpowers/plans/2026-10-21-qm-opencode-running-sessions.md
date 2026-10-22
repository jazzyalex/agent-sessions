# Plan: OpenCode running-sessions group in the Quota Meter

Revision 3, 2026-10-21. Source prompt: `docs/superpowers/plans/2026-10-21-qm-opencode-running-sessions-prompt.md` (Revision 2; was `docs/PROMPT_QUOTA_METER_OPENCODE_RUNNING_SESSIONS.md`).
Base commit: `9e71cf12` (main). Line numbers below are from this commit. `main` is now `67d1af54`; no Swift file changed in between.

**Owner decisions (2026-10-21, after review 1):**
- No scrolling. Raise the floating window's content cap from 270 pt to **500 pt**.
- **Hide the OpenCode group when there is no running OpenCode session.** This overrides the prompt's empty state ("No detected running sessions" is never shown). Accepted trade-off: less discoverable for users who have never had OpenCode running while the Quota Meter is open.
- Approved: edits to `AgentCockpitHUDWindow.swift` (cap), `Localizable.xcstrings`, and the chooser heading rename.
- Work happens directly in the main checkout.

Where this header conflicts with text below, the header wins. Superseded text is marked ~~struck~~ or replaced.

Revision 1 went through a Repo MCP review (ChatGPT web, Extra High, commit-pinned at `9e71cf12`, task `agent-sessions-qm-opencode-review-20261021`, run `bfb2a420`). Verdict **NO-SHIP**: one P1, six P2, two P3. The full answer is in `2026-10-21-qm-opencode-running-sessions-review-1.md`. This revision applies every finding. The P1 needs an owner decision (see "Approvals needed").

## Prompt analysis

The prompt's facts were written at `243eb191`. Re-checked at `9e71cf12`:

| Prompt claim | Status at 9e71cf12 |
|---|---|
| Strip and floating window share `AgentCockpitHUDView` | Holds. `hudStack` (`AgentCockpitHUDView.swift:1051-1082`) is used by both surfaces (`configuredHUDContent`, 996-1048). |
| OpenCode rows are built but not rendered | Holds. `makeRowsSnapshot` (1792-1998) emits `.opencode` rows. `HUDLimitsRowsPanel` (3772) uses `activeRows` only for Codex/Claude runway requests and `hasActiveRunwaySession` (3933-3944). Its body (4095-4167) renders only `entries` (Codex, Claude). |
| Group must be inside the measured region | Holds, but is not enough. The `GeometryReader` that emits `LimitsContentHeightKey` wraps the panel's whole `Group` (4156-4162). **The floating window then clamps that height to 9 × 30 = 270 pt** (`AgentCockpitHUDWindow.swift:121-125, 337-347`), fixes `minSize == maxSize` (194-205), and the content is clipped (`AgentCockpitHUDView.swift:1042`). See "Overflow". |
| Summary dedup differs from row dedup | Holds. `displayableLiveSummaryPresences` (1706-1734) uses TTY coalescing + `liveSummaryPresenceKey`. Rows use `dedupeRowsByResolvedSession` (2362+). |
| `AgentEnabledOpenCode` is not honoured by HUD filters | Holds. `OpenCodeSourceDescriptor.defaultEnabled = .always` is only the **fallback when no value is stored**. `AgentEnablement` seeding (`AgentEnablement.swift:171-226`) can write `false` on a machine without OpenCode. Reading the stored key never runs an availability probe. |
| Enablement is not a rebuild-gate input | Holds. `HUDRebuildGate.Inputs` (529-537) has no enablement field. |
| Global detection switch | `Cockpit.codexActiveSessionsEnabled` (`activeEnabled`, 662). When off, `canonicalRows = []` (858) and `disabledCallout` shows above the panel (1065-1069). |
| Probe filter | **Source-independent.** When `showProbePresences` is false, any supported presence (OpenCode included) whose workspace is a Codex or Claude probe directory is dropped (1846-1853; same in the summary path, 1706-1717). |
| Unresolved presences | `shouldHideUnresolvedPresencePlaceholder` (2334-2360): an unresolved `subagent` is always hidden, even with a session ID. Otherwise an unresolved OpenCode presence is hidden only when it has no session ID, no log path, no reveal URL / iTerm GUID / iTerm program, and no workspace match. A workspace match can resolve a presence before this check runs (1857-1894). |
| No OpenCode icon asset | Only `FooterIconClaude` and `FooterIconCodex` are in `Assets.xcassets`. `HUDLimitsProviderIcon` takes `UsageTrackingSource` (Codex/Claude only). The group uses the text label. |

Two gaps in the prompt that this plan resolves:

1. "Reuse the `HUDRow` mapping, spacing, type" — the panel has no `HUDRow` row view. Its session rows are runway rows (`HUDRunwayPanel`, 4603). The plan reuses runway text metrics, insets and separators, not the runway view (its rate cell and load bar would imply burn data) and not its row budget.
2. The prompt does not say which row list to use. The panel receives `displayState.rowsForDisplay`. The group filters that list and keeps its order.

## Decisions

- **Hide rule (owner decision).** Show the group only when:
  - live detection is on (`activeEnabled`); when off, the group is hidden and the existing `disabledCallout` explains it. Codex/Claude quota sections still render as today;
  - `AgentEnabledOpenCode` is on (`@AppStorage`, fallback `true`, matching `.always`);
  - at least one OpenCode row is present.
  There is no empty state and no indexed-history signal. The group appears when the first OpenCode session is detected and disappears when the last one ends.
- **Filter after the snapshot.** Enablement filtering happens in the panel, not in `makeRowsSnapshot`. No rebuild-gate change.
- **Order and count.** Filter `rowsForDisplay` to `.opencode`, drop repeated `HUDRow.id`s (keep the first), **keep the incoming order** (no second sort; `rowsForDisplay` already applies the HUD's priority order and its hidden-window churn rules, 1484-1564). `totalCount` is that array's count. The header count never comes from `liveSessionSummary`, from history, or from another filtered list.
- **Running** = every OpenCode row in `rowsForDisplay`, `.active` (working) or `.idle`.
- **Idle reason.** Both `.generic` and `.errorOrStuck` show "idle". The group never says "Stuck".
- **Probe / headless / unresolved.** The group adds no rule of its own; it shows what `makeRowsSnapshot` emits, under the source-independent probe rule and the unresolved rules above. Written in a doc comment and covered by tests.
- **OpenCode-only state** (no quota section shown, group visible): the group renders alone, without "No providers shown" / "Usage tracking is off". With the group hidden, `emptyRow` is unchanged.
- **Chooser.** OpenCode stays out of `QuotaMeterProvider`. Rename the popover heading "Agents shown" to "Usage sections shown" (P3). Keep its explanation text.
- **Display cap.** Own constant `OpenCodeHUDGroup.maxVisibleSessions = 4`, then "+N more". Not `HUDRunwayLayout.maxDetailRows`. The header shows the full total.

## Overflow (P1 — owner decision: 500 pt cap, no scrolling)

Today the floating window shows at most 270 pt of panel content (`limitsRowHeight 30 × limitsMaximumRows 9`, `AgentCockpitHUDWindow.swift:121-125, 337-347`) and clips the rest.

Fix:

- In `AgentCockpitHUDWindow.swift`, replace the `limitsRowHeight * limitsMaximumRows` clamp with a named constant `limitsMaximumContentHeight: CGFloat = 500`. Keep the 30 pt minimum. Remove `limitsMaximumRows` if nothing else reads it (grep first).
- Worst case to check fits: both providers + both runways (5 rows each) + Claude scoped-week line + Codex credits line + cloud status line + OpenCode header + 4 sessions + "+N more", with Enlarged font. Measure it in the throwaway render; if it exceeds 500 pt, report the number before changing anything else.
- Resize-anchor logic (`HUDLimitsResizeAnchor`, `lastLimitsGrowAnchoredTop`) is not touched. Re-run `HUDLimitsResizeAnchorTests` and check a grow near the bottom screen edge still keeps the window on screen.
- **Strip:** measure first. If the strip panel grows with content (`.fixedSize`, frame from the model), no change. If its frame is capped, report it before changing it.

## Layout

Inside `HUDLimitsRowsPanel.body`, inside the measured content:

```
VStack(spacing: 0)
  cloudStatusLine
  provider entries (unchanged)          ← or nothing in the OpenCode-only state
  [group separator: 7pt clear + 1pt rule at 0.18]   ← only if entries are non-empty
  HUDOpenCodeSessionsGroup
    header row  (providerRowHeight, 14pt inset):  Text(verbatim: "OpenCode") in .agentOpenCode, provider font
                                                  + "· N running" secondary (plural-aware)
    session rows (runwayRowHeight, runway font, 14pt inset, faint 0.5pt top rule like the runway)
       Text(verbatim: title) middle truncation  ……  "working" / "idle"
    "+N more" row when over the cap
```

There is no empty row: with zero OpenCode rows the group is not rendered.

## Code changes

1. **Preflight.** Read the newest `RepoHandover.md` entry. Run `git status`; do not touch files with someone else's uncommitted changes (`RepoHandover.md` is currently modified by the release session).
2. **Pure model** (internal, testable) in `AgentCockpitHUDView.swift`:
   ```swift
   struct OpenCodeHUDGroupModel: Equatable {
       let rows: [HUDRow]          // OpenCode rows from rowsForDisplay, deduped by id, incoming order
       var totalCount: Int { rows.count }
       let visibleRows: [HUDRow]   // rows.prefix(maxVisibleSessions)
       let overflowCount: Int      // rows.count - visibleRows.count
   }
   enum OpenCodeHUDGroup {
       static let maxVisibleSessions = 4
       static func make(rows: [HUDRow], detectionEnabled: Bool,
                        openCodeEnabled: Bool) -> OpenCodeHUDGroupModel?   // nil when hidden or zero rows
   }
   ```
3. ~~Derived-state history signal~~ — dropped (owner decision: hide when empty). `AgentCockpitHUDDerivedStateModel` is not changed.
4. **Wiring.** `hudStack` passes `detectionEnabled: activeEnabled` into `HUDLimitsRowsPanel`. The panel adds `@AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled = true`, builds the model once per body pass, and shows `emptyRow` only when the group is also hidden.
5. **View** `HUDOpenCodeSessionsGroup` (private) as laid out above.
6. **Overflow** — 500 pt content cap in `AgentCockpitHUDWindow.swift` (see "Overflow").
7. **Chooser heading** "Agents shown" → "Usage sections shown".
8. **Localization** (`docs/localization.md`): direct `Text` literals for "working", "idle", "Usage sections shown"; `LocalizedStringResource` with plural variants for "%lld running" and "+%lld more"; `Text(verbatim:)` for "OpenCode" and session titles. Add en + zh-Hans entries with translator comments to `Localizable.xcstrings`. Run `scripts/validate_localization_catalogs.py` and compile both `Localizable.xcstrings` and `InfoPlist.xcstrings` with `xcrun xcstringstool`.
9. **Test access.** Make `makeRowsSnapshot` and `HUDRowsSnapshot` internal. No behaviour change.

No new Swift files expected. If one is needed, use `scripts/xcode_add_file.rb` (exactly 4 `pbxproj` lines).

## Tests (TDD: write first, watch fail)

Tests go in `CodexActiveSessionsRegistryTests.swift` (already calls `AgentCockpitHUDView` statics) unless a new file is clearly better (then via `xcode_add_file.rb`). Add an OpenCode `HUDRow` fixture; the existing `makeHUDRow` (3129-3162) hardcodes Codex.

Pure model (`OpenCodeHUDGroup.make`):
- enablement off → `nil`; detection off → `nil`; zero OpenCode rows → `nil`;
- Codex/Claude rows ignored (only non-OpenCode rows → `nil`); duplicate ids count once; incoming order kept (no re-sort);
- `.errorOrStuck` idle row included;
- 1, 2, 4 and 6 rows (6 → 4 visible, overflow 2, total 6).

Window cap: a test that `limitsWindowHeight` clamps at 500 pt content (needs a small internal seam or a static helper for the clamp), plus the existing `HUDLimitsResizeAnchorTests`.

End to end (`@MainActor`; `CodexActiveSessionsModel()` is safe under the test host, 339-342; seed state with `debugApply`, 395-403, including explicit live-state classification for working vs idle; lookup indexes from OpenCode `Session` fixtures via `buildSessionLookupIndexes`):
- two presences resolving to one session → one row;
- probe filter: OpenCode presence in a Codex probe directory → excluded with `showProbePresences: false`, eligible with `true`;
- unresolved: subagent with session ID → hidden; session-ID-only → shown; focusable (reveal URL / iTerm) → shown; non-iTerm TTY-only with no workspace match → hidden; with workspace match → shown; two presences competing for one workspace match → second takes the next pool session or is dropped;
- headless mapper behaviour (synthetic no-TTY presence with a session ID → shown). This is a mapper test, not proof of real process discovery; the `PresenceEngine` eligibility rules are tested through their existing seams, or the report says they were not.
- working → idle transition changes the row's state, not its membership.

Mounted panel (retained, not throwaway): host `HUDLimitsRowsPanel` (made internal or via an internal test seam) with the usage models in the environment; assert the group appears/disappears when `AgentEnabledOpenCode` toggles while the snapshot is unchanged; the group disappears when the last OpenCode row goes away; OpenCode-only branch shows the group without "Usage tracking is off"; detection-off hides the group.

Localization: assert rendered "%lld running" and "+%lld more" for 1, 2 and 6 in `en` and `zh-Hans` (0 is never shown); one long-text render case.

Existing tests relied on: `shouldHideUnresolvedPresencePlaceholder` and live-state classifier tests in `CodexActiveSessionsRegistryTests` / `CodexActiveSessionsModelObservationTests` — listed in the final report.

## Verification

- Baseline xcresult counts before changes; one serialized `xcodebuild test` with `-derivedDataPath .deriveddata-tests`; counts after; explain any fall. Never open the app from that folder.
- Throwaway `ImageRenderer` test rendering the real panel: quota-only, OpenCode-only, both providers with runways, 1/4/6 sessions, zero sessions (group absent), detection off; light and dark; plus the worst-case height with Enlarged font (report its pt height against 500). Inspect PNGs, then delete the test. PNGs prove layout only, not detection or native window sizing.
- Overflow: check the floating window against the 500 pt cap and the strip. Say plainly what could not be checked natively.
- Localization validator + both catalogs compile.
- Real `opencode` session check (idle and working) if possible; otherwise say so.
- Restore macOS appearance to System if any step forced Dark Mode.

## Approvals

Granted 2026-10-21: 500 pt cap in `AgentCockpitHUDWindow.swift` (no scrolling), `Localizable.xcstrings` edits, chooser heading rename, hide-when-empty. Anything beyond these still needs the owner.

## Out of scope

OpenCode usage, subscription, cost, runway, strip cells, collapsed wings, `QuotaMeterProvider`, CHANGELOG, commits and branches.
