# Prompt: OpenCode sessions group in the Quota Meter (running sessions only)

Copy everything below the line into the implementing agent.

Revision 2, 2026-10-21. Revised after a ChatGPT Pro architecture pass over commit `243eb191` (unrecorded run: the owner sent the prompt by hand). Line numbers are from that commit and may have moved. Re-check them.

---

Read `RepoHandover.md` (newest entry), `agents.md`, `CLAUDE.md` and `docs/localization.md` first. Follow them. Then read `docs/adding-a-session-source.md`.

## Goal

Add one **OpenCode sessions-only group** to the shared HUD panel. It shows in the expanded strip and in the floating window. It lists running OpenCode sessions and a count. It has **no quota, no subscription data, no runway**. OpenCode subscriptions (OpenCode Go) are a later step that a community steward may take. Do not build them and do not imply they exist.

Do **not** extend quota models, `QuotaMeterProvider`, usage-source enums, strip wings, collapsed cells or runway code. This prompt authorizes only the small group below.

## What is true (verified at commit 243eb191)

- The expanded strip and the floating window use the same `AgentCockpitHUDView` (`QuotaStripController.swift:115-123`, `AgentSessionsApp.swift:469-480`). One change serves both.
- `PresenceEngine` detects candidate `opencode` processes, terminal and headless (`PresenceEngine.swift:1260-1271`, `1376-1407`).
- `makeRowsSnapshot` builds OpenCode `HUDRow` data. **The current quota panel does not render it.** `HUDLimitsRowsPanel` shows rows only through its Codex and Claude entries (`AgentCockpitHUDView.swift` around 1071-1076, 1792-1804, 3946-4016). A row can be valid and still invisible.
- OpenCode can reach the working state. The live-state classifier uses the iTerm processing signal or terminal tail, and log activity inside a 30-second window (`CodexActiveSessionsModel.swift` around 2173-2240, 2358-2368). The HUD maps `.activeWorking` to `.active`. An old idle-only probe is an owner observation, not a retained test.
- Idle reasons are heuristic. Activity older than 30 minutes with no detected prompt becomes `errorOrStuck` (`CodexActiveSessionsModel.swift` around 1857-1886). Do not show that as a confirmed failure.
- Detection limits: headless eligibility checks the executable, no TTY and not an app bundle, **not** a real conversation (`CodexActiveSessionsModel.swift` around 3419-3425). OpenCode log matching accepts only legacy `ses_*.json` (around 3197-3225), although other code reads the SQLite store. Do not promise complete SQLite or headless session identification.
- The enable preference key is `AgentEnabledOpenCode`. It defaults to enabled (`PreferencesConstants.swift:105`, `OpenCodeSourceDescriptor.swift:37,56`). Neither HUD presence-filter path checks it today (`AgentCockpitHUDView.swift` around 1706-1734, 1846-1853).
- A `.live` strip cell with no quota value shows "∞" and skips activity rendering (`QuotaStripCell.swift:54-79`). No existing cell state can show a session count honestly. Do not reuse those states.

## First step: investigate, then report before coding

Write a short plan in chat. Wait for approval if you need a new setting, a new layout pattern or a change outside `AgentCockpitHUDView.swift` and its tests. Answer:

1. Exactly where in `HUDLimitsRowsPanel` the group goes, and how it joins `LimitsContentHeightKey` measurement. Content outside the measured region was clipped before (`AgentCockpitHUDView.swift` around 4103-4108, 4157-4162). The group must be inside it.
2. How to count. The group count must come from **exactly the same filtered, deduplicated rows it displays**. `liveSessionSummary` coalesces and deduplicates with different keys than the row builder (around 1706-1771, 1938, 2362-2400). Do not mix them.
3. How to honour `AgentEnabledOpenCode` and the global live-detection setting **immediately**, in both the rows and the count. Enablement is not an input to the HUD rebuild gate (around 397-447, 516-538). If you filter inside the cached builder, add invalidation. Filtering after the snapshot is also allowed.

## Contract

- "Running" means **eligible detected live sessions, working or idle**. It does not mean all indexed history. It does not mean only `.activeWorking`.
- Reuse the `HUDRow` mapping, spacing, type and group separators. Reuse the existing OpenCode colour and label.
- Empty state: "No detected running sessions" (localized). Do not claim that none exist.
- Default-enabled means users without OpenCode would see an empty group. Decide on purpose whether to hide the group when OpenCode is disabled or has never been detected. Say which you chose and why.
- Handle the detection-disabled state and the OpenCode-only state explicitly. The panel's empty branch today says "No providers shown" or "Usage tracking is off" (around 858, 1065-1068, 4099-4101, 4242-4255).
- Define what happens to probe and headless candidates and to unresolved presences. Unresolved OpenCode presences can be hidden today (around 1846-1853, 2334-2359). Write the rule down and test it.
- Copy must not say "limit", "quota left" or "runway" for OpenCode.
- Keep OpenCode out of the quota models. The "Agents shown" chooser describes usage sections (around 4500-4525). Make sure it does not suggest OpenCode has quota data, and clarify its scope if it does.
- Performance: reuse the cached snapshot. Add no history scan, no poller and no filesystem lookup. Do not call `AvailabilityContext.live()` on a hot path (`SessionSourceDescriptor.swift:165-170`).

## Build rules

- Localization: follow `docs/localization.md`. It sets different rules for direct SwiftUI literals, reusable `LocalizedStringResource`, and verbatim session titles and provider names. Update and validate both string catalogs, including `zh-Hans` and plural forms. Test counts 0, 1 and 2, and long text.
- If you add Swift files, use `scripts/xcode_add_file.rb`. A correct run adds exactly 4 `pbxproj` lines.
- Use the Edit tool for edits. No inline Python.

## Verify

- Tests, with retained regressions for: enablement on and off, duplicate identities, probe and headless candidates, unresolved rows, working and idle activity, and the empty state. Write a new behavior test first and watch it fail. Existing classifier tests may already pass; say which ones you relied on.
- Test counts are an alarm, not an invariant (`agents.md` section on test counts). Report aggregate xcresult counts before and after, and explain any fall.
- Render the **populated** and the **empty** group, as part of the real panel, to PNGs with `ImageRenderer` in a throwaway test. Look at them. Remove the throwaway test afterwards. A PNG shows layout only. It does not prove detection or native-window sizing, so say so.
- Run **one** serialized `xcodebuild` at a time, with `.deriveddata-tests`. Never open the app from that folder. The test host opens the real `index.db` at startup.
- If you can run a real `opencode` session here, check that the group lists it while it is idle and while it works. Say plainly if you could not.

## Do not

- Do not add OpenCode usage, subscription, cost or runway code.
- Do not scrape the OpenCode web console or read any cookie.
- Do not commit, push, or create or switch branches. The owner asks for each of these.
- Do not edit files that already have uncommitted changes from someone else. Check `git status` first.
- Do not use computer-use for QA.
- Do not edit `CHANGELOG.md` or release copy. Put one line in your final report instead.

## Final report

Keep it short. State: files changed; what the group shows and when it hides; test results with counts; PNG paths; what you could not verify (especially real OpenCode detection, the working state, and native-window sizing); and one line the owner can use in a steward post about what OpenCode support does and does not cover.
