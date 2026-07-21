# Quota Meter click-to-focus + Agent Cockpit deprecation — implementation plan

Status: plan, awaiting approval. No code written.
Branch: `feat/universal-click-to-focus` (current; no new branches without explicit approval per `agents.md` "Git Branch and Worktree Safety").
Companion spec: `docs/superpowers/plans/2026-07-20-universal-click-to-focus.md` — its "Verified findings" are ground truth and are not re-derived here.

Two features, one program:

- **Feature 1 — Universal click-to-focus.** Fully specified in the companion spec. Rule, sequencing (A → C → B), Codex multi-session Option B, and visual surface are decided. This plan only turns it into ordered, executable steps.
- **Feature 2 — Full deprecation of the Compact and Full Agent Cockpit.** Only the Quota Meter (the `.limits` mode) survives. Designed in this document.

Commit protocol for every phase: Conventional Commits with `Tool:` / `Model:` / `Why:` trailers, owner-authored, no co-author lines, commits only on explicit owner request, and `git commit -- <paths>` scoped to intended files only. Test wrapper: `./scripts/xcode_test_stable.sh`. Every phase is a "significant change" under `agents.md` and must build before being presented.

---

## Part I — Deprecation design (the seven questions)

### Q1. What happens to the "Agent Cockpit" name

**Decision: user-facing strings change to "Quota Meter" now; internal identifiers, file names, and persisted keys keep their names. A single optional mechanical rename commit is deferred until after both features land, owner-approved.**

Justification:

- `AgentSessions/Views/AgentCockpitHUDView.swift` is 6,459 lines (verified `wc -l`). Feature 1 phase B edits the same file. A rename mid-program guarantees merge pain across the F-B work and any parallel session sharing the worktree, plus `project.pbxproj` churn, for zero user-visible value.
- The window identifier `"AgentCockpit"` is load-bearing persisted state, not just a name: the scene id (`AgentSessions/AgentSessionsApp.swift:494`), the `AppWindowRouter` lookups (`AgentSessionsApp.swift:75`, `:86`, `:90`, `:106`), and the configurator's identifier re-stamp (`AgentSessions/Views/AgentCockpitHUDWindow.swift:240-242`) all key on it, and NSWindow restoration state references it. Same for the frame autosave name `"AgentCockpitHUDWindow.limits"` (`AgentCockpitHUDWindow.swift:148`) — renaming it silently drops every existing user's Quota Meter position. **Both stay.**
- `PreferencesKey.Cockpit.*` string values (`AgentSessions/Views/Preferences/PreferencesConstants.swift:179-195`) are persisted UserDefaults keys. Retained keys keep their strings; removed keys are deleted plus cleaned from UserDefaults (Q4).
- `PreferencesTab.agentCockpit` (`AgentSessions/Views/PreferencesView.swift:1068`): its raw value is persisted via `lastSelectedTab` (`PreferencesView.swift:12`), but restore already fails soft to General on an unknown raw value (`PreferencesView.swift:313-314`, which even special-cases a previously retired `.droidCLI`). So a case rename is *safe* but still deferred to the optional rename commit; only its `title` ("Agent Cockpit" → "Quota Meter", `PreferencesView.swift:1092`) changes now. Icon `rectangle.3.group` (`PreferencesView.swift:1116`) may change to `gauge` in the same edit — owner's call, default is keep.
- `CockpitNavigationBridge`, `CockpitWindowVisibility`, `AgentCockpitMenu`, `AgentCockpitHUDDerivedStateModel`: internal, keep (the menu struct is rewritten anyway in Q2 and may be renamed in place since it is private to `AgentSessionsApp.swift` — free).
- `CockpitFooterView.swift` is **not** Cockpit code despite the name: it is the main window's status footer, constructed at `AgentSessions/Views/UnifiedSessionsView.swift:1017` and tested by `AgentSessionsTests/FooterSourceTagTests.swift`. It survives untouched; rename only in the deferred pass.

User-facing strings that change to "Quota Meter" (complete inventory, all verified):

| Location | Current | Becomes |
| --- | --- | --- |
| `AgentSessionsApp.swift:494` | `Window("Agent Cockpit", id: "AgentCockpit")` | title `"Quota Meter"`, id unchanged |
| `AgentSessionsApp.swift:641-663` | menu `"Quota Meter / Agent Cockpit"` + items | replaced entirely (Q2) |
| `MenuBar/StatusItemController.swift:233` | "Open Agent Cockpit" / "Hide Agent Cockpit" | "Open Quota Meter" / "Hide Quota Meter" |
| `Views/UnifiedSessionsView.swift:1873-1881` | toolbar help "Open Agent Cockpit." / label "Agent Cockpit" | "Open Quota Meter." / "Quota Meter" |
| `Views/PreferencesView.swift:1092` | tab title "Agent Cockpit" | "Quota Meter" |
| `Views/Preferences/PreferencesView+General.swift:107` | tab heading "Agent Cockpit" | "Quota Meter" |
| `Views/Preferences/PreferencesView+General.swift:122-123` | "Enable live session detection + Cockpit (Beta)" + help | "…detection (Beta)"; help drops Cockpit wording |
| `Views/Preferences/PreferencesView+UsageProbes.swift:284` | "Show probe sessions in Cockpit HUD (debug)" | "…in Quota Meter (debug)" |
| `Views/AgentCockpitHUDView.swift:1462` | help "Open Agent Cockpit settings" | "Open Quota Meter settings" |
| `Views/AgentCockpitHUDView.swift:6449` | `#Preview("Agent Cockpit HUD")` | "Quota Meter" |
| `README.md:101`, `:118-145` | "Agent Cockpit" feature sections | rewritten around Quota Meter (Phase D1 docs step) |
| `Views/Preferences/PreferencesView+General.swift:212-215` and `AgentSessionsApp.swift:663` help copy | "Cockpit" phrasing | "Quota Meter" phrasing |

The toolbar button label "Enable Live sessions + Cockpit (Beta) in Settings → Agent Cockpit" (`UnifiedSessionsView.swift:1874`) and the equivalent menu help (`AgentSessionsApp.swift:663`) update to the new tab/toggle names in the same pass.

### Q2. The View menu, item by item

Today (`AgentSessionsApp.swift:630-698`): a submenu "Quota Meter / Agent Cockpit" holding modeItem(.limits) with Cmd+Opt+Shift+C, modeItem(.compact), modeItem(.full), "Cycle Cockpit View" with Cmd+Shift+M calling `currentMode.next()` (`AgentCockpitHUDView.swift:229-235`), and an Off toggle. A submenu with one mode is wrong, so:

**Decision: the submenu is deleted. It is replaced by a single top-level View-menu toggle.**

View menu after Phase D1, in order:

1. **Toggle "Quota Meter" — Cmd+Opt+Shift+C.** Checkmark = window on screen, driven by `CockpitWindowVisibility.shared` (`AgentSessionsApp.swift:594-619`, kept as is). Checking opens via the existing registered `openWindow(id: "AgentCockpit")` path; unchecking calls `AppWindowRouter.closeAgentCockpitWindow()` (`AgentSessionsApp.swift:89-91`). This is standard macOS View-menu show/hide semantics (like "Show Sidebar"). It deliberately changes one behavior: today Cmd+Opt+Shift+C on an already-visible QM re-selects/brings-to-front (`AgentSessionsApp.swift:667-677`); after D1 it hides it. The bring-to-front case only matters for an unpinned QM buried under other windows — the QM's normal state is pinned at `.statusBar` level (`AgentCockpitHUDWindow.swift:143`). Accepted trade; noted for the CHANGELOG.
2. Keep the `.disabled(!liveSessionsFeatureEnabled)` gate and its help text exactly as the submenu has today (`AgentSessionsApp.swift:659-664`), with the help strings reworded per Q1. Whether the QM should be reachable with the live-sessions beta off is a real product question (the limits panel works without live sessions) — **explicitly out of scope; recorded as a follow-up**.
3. Everything else in the View menu (`AgentSessionsApp.swift:432-450`: Image Browser, Saved Sessions, Saved Only, Transcript Window, Collapse/Expand All, appearance items) is untouched.

**Cmd+Shift+M is retired, not repurposed.** With one mode, "cycle" is meaningless. Repurposing it as a second show/hide toggle would duplicate Cmd+Opt+Shift+C and silently invert its meaning under existing users' fingers ("next view" becoming "hide the window" is a worse surprise than a dead chord). The shortcut is freed; its removal goes in the CHANGELOG. The hidden-button comment trail at `AgentCockpitHUDView.swift:1815-1817` is removed with it.

The "Off" item, `modeItem(_:_:)`, `offItem`, `select(_:)`, and `currentMode` (`AgentSessionsApp.swift:636-698`) are all deleted; the replacement toggle needs only `CockpitWindowVisibility` and the two router calls. The doc comments at `:585-592` and `:621-629` are rewritten to describe the single toggle.

### Q3. Migration for users persisted on `.full` / `.compact`

Persisted state involved (all verified):

- `CockpitHUDDisplayMode` string — read by `initialMode()` (`AgentCockpitHUDView.swift:220-227`) and five `@AppStorage` sites (`AgentSessionsApp.swift:633`, `OnboardingListTopSlot.swift:176`, `PreferencesView.swift:30`, `AgentCockpitHUDView.swift:705`, plus the computed fallback at `:802-803`).
- `CockpitHUDCompact` legacy Bool — fallback in `initialMode()` (`:225-226`), fallback in the computed property (`:803`), kept in sync by `setHUDDisplayMode` (`:1312-1315`), `select()` (`AgentSessionsApp.swift:695`), the Settings picker (`PreferencesView+General.swift:169`), and onboarding (`OnboardingListTopSlot.swift:208-212`).
- The legacy-value repair path `normalizeHUDDisplayMode()` (`AgentCockpitHUDView.swift:1299-1310`), run from the HUD's `onAppear` (`:884` region) and on every raw-value change (`:1004-1006`).
- Per-mode window frame autosaves `AgentCockpitHUDWindow.full` / `.compact` / `.limits` (`AgentCockpitHUDWindow.swift:146-148`) plus in-memory `cachedFrameByMode` (`:163`).

**Migration mechanics, two stages:**

**Stage 1 (Phase D1, enum still exists — behavior migration).** `initialMode()` is changed to return `.limits` unconditionally, and `normalizeHUDDisplayMode()` is changed to repair *any* stored value (including valid `.full`/`.compact` and the legacy Bool) to `.limits` via the existing `setHUDDisplayMode(.limits)`, which also rewrites `hudCompact` to `true` (`:1312-1315`). Net effect: every launch and every stale write lands the user on the Quota Meter, using only the repair machinery that already exists. No empty or broken window is possible because the mode the view renders is always `.limits` and the window configurator's `.limits` path is untouched. A user coming from `.full` has no saved `AgentCockpitHUDWindow.limits` frame; `applyModeTransition` already handles that by falling through to `applyLimitsDefaultSize` (`AgentCockpitHUDWindow.swift:485-496`) — the QM appears at its default size, positioned by the system. Verified-by-construction, and covered by a unit test on `initialMode(defaults:)` with primed suites (`full`, `compact`, legacy-Bool-only, garbage raw, empty).

**Stage 2 (Phase D2a, enum deleted — key removal).** Once nothing reads the mode, the keys are removed from UserDefaults by an idempotent startup cleanup (Q4). Writing `.limits` first in Stage 1 is deliberate: it keeps the D1 build coherent while `@AppStorage` readers still exist, and makes D1 shippable on its own.

Onboarding already lands new users on `.limits` (`OnboardingListTopSlot.swift:208-212`); in D2a its two mode writes are deleted (the promo activator keeps enabling usage tracking and calling `AppWindowRouter.showAgentCockpitWindow()`, `OnboardingListTopSlot.swift:203-215`).

### Q4. Preference keys: removed, retained, cleaned

From `PreferencesConstants.swift:179-195` (`PreferencesKey.Cockpit`):

**Removed (code + key constant deleted, value cleaned from UserDefaults):**

| Key | Why dead | Consumers deleted |
| --- | --- | --- |
| `hudDisplayMode` (:189) | mode machinery gone | Q3 sites |
| `hudCompact` (:190) | legacy mode Bool | Q3 sites |
| `hudCompactBaselineRows` (:183) | compact sizing | `AgentCockpitHUDView.swift:708`, `PreferencesView.swift:32`, picker `PreferencesView+General.swift:184-193`, window math `AgentCockpitHUDWindow.swift:595-650` |
| `hudCompactAutoFitEnabled` (:184) | compact auto-fit | `AgentCockpitHUDView.swift:723`, `PreferencesView.swift:33`, toggle `PreferencesView+General.swift:195-196` |
| `hudShowAgentNameInCompact` (:182) | compact rows die | `AgentCockpitHUDRowView.swift:20`, `PreferencesView.swift:31`, toggle `PreferencesView+General.swift:181-182` |
| `showTabSubtitleInFullMode` (:185) | full rows die | `AgentCockpitHUDRowView.swift:21,:75`, `PreferencesView.swift:34`, toggle `PreferencesView+General.swift:201-202` |
| `hudShowLimits` (:192) | Full/Compact footer (`HUDLimitsBar`) dies | `AgentCockpitHUDView.swift:724`, gate `:1171-1173`, toggle `PreferencesView+General.swift:203-204` |
| `hudGroupByProject` (:188) | Cockpit grouping dies | `AgentCockpitHUDView.swift:704`, toggle `:1420-1430`, grouping pipeline |
| `codexLiveFilterMode` (:186) | **already orphaned today** — `rg` finds no consumer outside the constant definition | none |

**Retained (verified live consumers outside the deprecated surface):**

- `codexActiveSessionsEnabled` (:180) — gates the whole presence pipeline, the QM disabled-callout (`AgentCockpitHUDView.swift:1147`), the menu gate (`AgentSessionsApp.swift:634`), launch restore (`AgentSessionsApp.swift:94-97`), Dock policy (`Services/ActivationPolicyDecider.swift:23`).
- `codexActiveRegistryRootOverride` (:181) — Settings field `PreferencesView+General.swift:126-145`.
- `hudOpen` (:187) — presence cadence input (`Services/CodexActiveSessionsModel.swift:261-262`, `:559`; `Services/PresenceEngine.swift:11,:20-21`); written by the HUD's appear/disappear (`AgentCockpitHUDView.swift:889,:898`).
- `hudPinned` (:191) — pin button (`AgentCockpitHUDView.swift:1498+`), launch restore (`AgentSessionsApp.swift:96`), Dock policy (`ActivationPolicyDecider.swift:24`).
- `hudReduceTransparency` (:194) — QM background material (`AgentCockpitHUDView.swift:725,:729-733`), Settings toggle (`PreferencesView+General.swift:113`).
- `showProbeSessionsInHUD` (:193) — row-pipeline debug filter used by the shared pipeline that still feeds the QM and menu bar counts (`AgentCockpitHUDView.swift:442,:550,:606,:2386`).

**Cleanup mechanism.** A small `removeObject(forKey:)` sweep over the nine removed keys, run unconditionally from the shared launch bootstrap (`runSharedLaunchBootstrap`, referenced at `AgentSessionsApp.swift:489,:508`). `removeObject` is idempotent and cheap, so no versioned migration flag is needed (also consistent with the repo's no-feature-flags policy, `agents.md` "Feature Flags Policy"). The sweep also removes the two orphaned per-mode frame autosaves. Hypothesis: AppKit stores them under defaults keys of the form `"NSWindow Frame AgentCockpitHUDWindow.full"` / `"...compact"` — verify the exact key strings on a live defaults domain before writing the list; if the format differs, clean whatever key `defaults read` actually shows. `AgentCockpitHUDWindow.limits` is **not** cleaned (it is the live QM position).

### Q5. Deleted vs merely unreachable

Rule: nothing ships merely-unreachable except `CockpitView.swift` (pre-existing dead code, separately tracked, untouched here — companion spec "Verified findings" 3). Everything the deprecation orphans is deleted in D2a/D2b, compiler-verified.

**Whole files deleted (D2a), removed from `project.pbxproj` (file reference + build file; no add-script exists for removal, so edit pbxproj and then run `xcodebuild -resolvePackageDependencies` + build per `agents.md` "CRITICAL: After ANY modification to project.pbxproj"):**

- `AgentSessions/Views/AgentCockpitHUDRowView.swift` (348 lines) — constructed only at `AgentCockpitHUDView.swift:1698`, `:1717`, `:1776` (all inside `bodyList`/`compactCenteredBodyRows`, deleted) and its own preview (`AgentCockpitHUDRowView.swift:320`).
- `AgentSessions/Views/AgentCockpitHUDGroupHeader.swift` (67 lines) — constructed only at `AgentCockpitHUDView.swift:1686`.

**Not deleted, explicitly:** `CockpitFooterView.swift` (main-window footer, `UnifiedSessionsView.swift:1017`), `CockpitView.swift` (separate cleanup), `HUDRunwayPanel` (`AgentCockpitHUDView.swift:5228`) — it is the QM's Session Runway drawer (used at `:5076` inside `HUDLimitsRowsPanel`) and the very surface F-B builds on; its second call site `:4701` (inside `HUDLimitsBar`'s hover drawer) disappears with `HUDLimitsBar`.

**Partial deletions in `AgentCockpitHUDView.swift` (D2a), symbol-level with anchors** (line numbers are anchors as of this writing, not offsets to apply blindly):

- `enum AgentCockpitHUDDisplayMode` entirely (`:198-236`) and every reader: `:705-706`, `:802-804`, `:826-832` (`isCompact` becomes constant-true semantics; `isLimitsOnly` disappears — see D2a step 3), `:871` (`initialCompact` arg to `AgentCockpitHUDDerivedStateModel` becomes literal `true`), `:1004-1006`, `:1299-1315`.
- `enum HUDSessionFilterMode` (`:238-242`), `sessionFilterMode`/`filterText`/`searchFocusToken`/`isSearchFocused` state (`:735-739`, `:767`), filter pills (`:1323-1363`), `HUDFilterPillStyle` (definition — locate by name), search row + By Project button (`:1403-1435`), `HUDSearchField` (`:6345+`), `focusSearchField` (`:2186-2191`), `filteredRows` instance + static (`:1879-1881` and the static it calls).
- `bodyList` (`:1665-1750`), `compactBodyMinHeight` (`:1758-1769`), `compactCenteredBodyRows` (`:1771-1789`), `shouldCenterCompactRows` (`:1791-1798`), `emptyState`/`fullModeEmptyStateLabel` (`:1900-1932`; the QM has its own `emptyRow` inside `HUDLimitsRowsPanel`), `staleGroupsDivider` (`:1890-1898`), `shouldShowStaleGroupsDivider` (`:2152-2158`), `fullUngroupedLayoutSignature` (`:1934-1945`).
- Grouping/collapse machinery: `groupByProject` storage (`:704`), `collapsedProjects`/`staleAutoCollapsedProjects`/`manuallyExpandedStaleProjects` state (`:737`, `:762-763`), `toggleCollapsed` (`:1864-1877`), `groupedRows` instance (`:1883-1888`), `synchronizeCollapsedProjectsForStaleGroups` call sites (`:1002`, `:1034`) and the static helper + `HUDGroup`/`collapseSyncKey` support (`:244-272`) *if* nothing else references them after the sweep — the deletion is compiler-driven, see the D2a rule below.
- Cockpit-only row actions: `focus(_ row:)` (`:2193-2201`), `rowContextMenu` (`:2203-2249`) including its two "Focus in iTerm2" strings (`:2213-2217`), `canFocus` (`:2251-2257` — this is the focus-gate caller the companion spec's call-site table lists as "dies with the Cockpit"), `revealLog`/`openWorkingDirectory`/`copyToPasteboard`/`normalizedTabTitle` helpers (`:2315-2329+`) where no surviving caller remains. **Kept:** `goToSession` (`:2259-2292`) and `postGoToSessionNotification` (`:2294-2313`) — feature 1's `.transcript` branch is built on them (companion spec, "Verified findings" 4) — plus `CockpitNavigationBridge` (`AgentSessionsApp.swift:1310+`).
- `hiddenShortcuts` (`:1805-1852`): delete the Cmd+K search focuser (`:1807-1813`) and the Cmd+1..9 / Cmd+0 row-focus buttons (`:1831-1850`) and `renderedRows` static (`:1854-1862`); **keep** the Cmd+W close handler (`:1822-1829`) — the QM's chrome has no close button (`AgentCockpitHUDWindow.swift:411-419`), so Cmd+W stays load-bearing.
- `HUDLimitsBar` (`:4188` to end of struct, several hundred lines including its `expandedPanel`) and `HUDLimitsBarContent` (`:5711+`, single call site `:4362` inside `HUDLimitsBar`) and the `showLimits` gate (`:1171-1173`). Verify `HUDWindowExpansionDirectionReader` and `HUDExpansionDirection` have no surviving references before deleting them with it.
- `hudStack` (`:1132-1177`) collapses: the `isLimitsOnly` branch body remains, the `bodyList` and `HUDLimitsBar` branches go.
- Header (`:1317-1437`) collapses to the QM branch: destinations zone (`:1364-1372`) + `limitsToolbarCluster` ViewThatFits (`:1376-1387`); the non-limits toolbar cluster (`:1388-1397`) and the full-mode search row (`:1403-1435`) go. Toolbar buttons `cockpitOpenButton`, `cockpitSettingsButton`, `cockpitFontSizeButton`, `cockpitChromeButton`, `cockpitPinButton`, runway/probe popovers (`:1439-1660`) all survive — they are the QM's chrome.
- Compact hover/dwell machinery (`:1196-1297`) **survives** — it is the QM's chrome-reveal system (`QuotaMeterChrome`, `Views/../UsageDisplayMode.swift:118+`), not a Compact-cockpit feature; only its `guard isCompact` early-outs simplify.
- `#Preview` (`:6449`) retitled.

**Partial deletions in `AgentCockpitHUDWindow.swift` (D2b):**

- Deleted: internal `Mode` enum (`:109-113`) or collapsed to nothing; `restoreStandardChrome` (`:422-442`); `applyFullDefaultSize` (`:652`); `applyCompactDefaultSize` (`:564`); `applyCompactBaselineHeight` (`:610`); `applyCompactVisibleRowsAutoHeight` (`:631`); `shouldApplyCompactBaselineHeight` (`:599`); `clampedPreferredCompactRows` (`:595`); `compactMinimumWindowHeight` (`:536`); `compactContentHeight` (`:547`); the full/compact branches of `applyStyle` (`:255-352` — keeps only the limits path and the pin block `:354-363`); `cachedFrameByMode` (`:163`, only meaningful across mode switches); `applyModeTransition` (`:461-511`) reduced to first-attach restore of the `.limits` autosave frame with `applyLimitsDefaultSize` fallback; `autosaveName(for:)`/`inferredMode` (`:513-529`) reduced accordingly; full/compact constants (`:146-147`, `:149-155`, `:160-162`); `window.title = "Agent Cockpit (n)"` (`:349`).
- Kept: `applyCompactChrome` (`:395-420`, becomes unconditional QM chrome), baseline capture (`:377-393` — still needed so unpin restores sane level/behavior), `sanitizedUnpinnedLevel`/`sanitizedUnpinnedCollectionBehavior` (`:366-375`, unit-tested in `CodexActiveSessionsRegistryTests`), `limitsWindowHeight` (`:551`), `applyLimitsDefaultSize` (`:669`), `shouldGrowLimitsWindowDown` (`:729`), `setWindowFrame` (`:743`), `HUDLimitsResizeAnchor` (`:13-23`), pinning constants (`:143-144`), autosave name `"AgentCockpitHUDWindow.limits"` (`:148`).
- `StyleInputs` (`:115-127`) shrinks: drop `isCompact`, `isLimitsOnly`, `shownSessionCount`, `groupByProject`, `compactPreferredRows`, `compactAutoFitEnabled`; keep `isPinned`, `limitsContentHeight`, `limitsContentWidth`, `activeEnabled`, `compactToolbarVisible` (still drives limits height when chrome shows/hides, `:238`, `:299-302`). `AgentCockpitHUDWindowConfigurator`'s call site (`AgentCockpitHUDView.swift:1100-1112`) shrinks to match.

**Cockpit-only functionality that dies with it (owner-visible inventory for the CHANGELOG):** the session search field, By Project grouping, All/Active/Idle filter pills, Cmd+1..9/Cmd+0 row focus and Cmd+K search shortcuts, the row context menu (Go to Session / Focus in iTerm2 / Reveal Log / Open Working Directory / three Copy items, `AgentCockpitHUDView.swift:2203-2249`), row click-to-focus via the Cockpit's Button rows, the full-mode toolbar row, the Full/Compact footer Quota Meter bar with its hover drawer, per-mode window sizes, and the Cmd+Shift+M cycle. The QM keeps: provider limits rows, Session Runway drawer, chrome modes (always/on-hover/on-demand), pin, enlarged text, probe/runway popovers, open-main-window and settings buttons, Cmd+W. Feature 1 phase B then gives QM rows a *better* replacement for row focus than the Cockpit ever had.

### Q6. Interleaving the two features

**Decision: deprecation first, entirely; then feature 1 in its decided A → C → B order.**

Combined order: **D1 → D2a → D2b → F-A → F-C → F-B** (→ optional rename/docs pass).

Justification:

- **D before A.** The companion spec deliberately froze `canAttemptITerm2Focus`'s name so the Cockpit's out-of-scope callers "keep compiling untouched until the Cockpit is removed" (spec, "Call sites"). Removing the Cockpit first deletes that caller (`AgentCockpitHUDView.swift:2251-2257`), so F-A lands against a call-site table of exactly one live consumer (`UnifiedSessionsView.swift:3027/:3040`) plus the dead `CockpitView.swift`. No compatibility contortions, smaller diff, cleaner review.
- **D before C.** C changes the live-row population. With the Cockpit gone, those new desktop rows need QA on two surfaces (main list, QM) instead of three, and no time is spent making rows render correctly in list modes that are about to be deleted.
- **D before B.** B is the risky phase (drag shim on the window with two rolled-back interaction changes). Doing it against a QM-only view and a collapsed window configurator means the gesture work is QA'd once, against the final chrome, with no mode-switching interactions to re-test. The spec's follow-up (non-activating panel) also explicitly wants the deprecation landed first.
- **D is not split across F phases.** Interleaving would force re-verification of the same file (`AgentCockpitHUDView.swift`) after every step for no dependency reason.
- **A → C → B is unchanged** — re-confirmed in the spec after the deprecation decision ("Sequencing", including why not C first and why B last). Not relitigated here.
- Cost acknowledged: the headline click-to-focus capability lands three phases later than it would if F-A went first. Accepted: D1/D2a are mostly mechanical deletions, each independently buildable and reviewable, and they de-risk everything after.

### Q7. Test strategy

Suite baseline: ~1,725 tests, 3 skipped, green as of `RepoHandover.md` 2026-07-19 entries. Runner: `./scripts/xcode_test_stable.sh` after every phase.

**Existing tests that break, per phase:**

- **D1:** none expected — the enum and all helpers still exist. Tests referencing `AgentCockpitHUDDisplayMode.initialMode()` behavior do not exist today (verified by grep); the new D1 tests are additive.
- **D2a:** tests die *only with their symbol*. `CodexActiveSessionsRegistryTests.swift` (147 "Cockpit" references) exercises static helpers: `navigationConfidence`, `mergeMetadata`, `displayPriority`, `groupedRows`, `synchronizeCollapsedProjectsForStaleGroups`, `liveSessionSummary`, `hasMembershipChurn`/`hasPriorityChurn`, `projectLabel`, `shouldHideUnresolvedPresencePlaceholder`, and the window `sanitized*` statics. The ones whose symbols survive the compiler-driven sweep keep their tests; tests for deleted symbols (grouping/collapse-sync at minimum) are deleted in the same commit. Do not delete a test to make a sweep easier — a test failing is a signal to re-check whether the symbol is genuinely orphaned.
- **D2b:** `sanitizedUnpinnedLevel` / `sanitizedUnpinnedCollectionBehavior` tests keep passing (symbols kept). Any test constructing `StyleInputs` (none found by grep; verify at implementation) updates to the shrunk struct.
- **Unaffected (verified consumers):** `CodexUsageParserTests` QuotaMeterChrome suite (chrome enum survives), `FooterSourceTagTests` (CockpitFooterView survives), `ActivationPolicyDeciderTests` (`hudPinned`/`codexActiveSessionsEnabled` retained), `OnboardingQuotaMeterCardTests` (coordinator logic; `noteCockpitOpened` at `AgentSessionsApp.swift:512` survives), `PresenceEngineRegressionTests` (D phases do not touch the presence pipeline), `SessionListFingerprintTests`, `CodexResume*`.
- **F-C** is the phase most likely to break presence tests intentionally — `PresenceEngineRegressionTests` and registry coalescing tests assert current tty-gate behavior; expected diffs are part of that phase's review.

**New coverage, per phase:**

- D1: `initialMode(defaults:)` returns `.limits` for primed suites {full, compact, legacy `hudCompact` true, legacy false, garbage, empty}; menu-level behavior is manual QA (SwiftUI `Commands` are not unit-testable here).
- D2a: defaults-cleanup unit test — primed removed-keys + retained-keys suite; assert removed gone, retained intact.
- F-A: resolver precedence tests (`.itermTab` > `.desktopApp` > `.terminalApp` > `.transcript`), no-launch rule (unresolvable bundle id → `.transcript`, never `NSWorkspace.launch`), `TerminalKind` bundle-id fallback, gate-string selection for the `UnifiedSessionsView.swift:3033` label. Resolver must be a pure function over presence fields plus an injected running-apps lookup so all of this is unit-testable.
- F-C: `parsePSCommandListOutput` fixtures with `??` tty for desktop command paths pass Gate A; Gate B predicate truth table; Electron main process (`/Applications/Claude.app/Contents/MacOS/Claude`, no session log) falls out — the spec flags this as needing an explicit test; `coalescePresencesByTTY` dedup counts with added tty-less presences.
- F-B: pure row-to-destination mapping tests (identity `logPaths` → presence match vs `SessionLookupIndexes.byLogPath` fallback); aggregate-row action as an extracted decision function. The drag shim and hover affordance are manual QA (acceptance list below) — do not attempt to unit-test AppKit gesture routing.

---

## Part II — Phased execution

Every phase ends with: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` clean, `./scripts/xcode_test_stable.sh` green, a CHANGELOG bullet under `[Unreleased]` for user-visible changes (`agents.md` "User-Visible Changes"), and the listed manual QA. Owner QA is batched at feature-complete points (D2b, F-A, F-C, F-B) per the house preference; the per-phase checklists are for the implementing agent. Build for owner launch via a non-test derived-data path (never `open` the `xcodebuild test` bundle — see global CLAUDE.md).

### Phase D0 — Preflight

1. Confirm branch is `feat/universal-click-to-focus`, worktree clean of unrelated changes.
2. Run the full suite once for a baseline count.

Gate: baseline recorded.

### Phase D1 — Deprecation switch-over (behavior-preserving for the QM)

Everything a user can see changes here; almost nothing is deleted yet. The enum survives so the build stays coherent.

1. **Migration:** `initialMode()` → always `.limits`; `normalizeHUDDisplayMode()` → repair any non-limits state to `.limits` (`AgentCockpitHUDView.swift:220-227`, `:1299-1310`). Add the unit tests from Q7.
2. **View menu:** replace `AgentCockpitMenu` per Q2 (`AgentSessionsApp.swift:630-698`); retire Cmd+Shift+M; delete the `:1815-1817` comment.
3. **Settings:** in `agentCockpitTab` (`PreferencesView+General.swift:105+`) delete the "Compact Mode" section (`:162-197`) and the "Full Mode" section (`:199-205`); retitle the tab heading (`:107`) and `PreferencesTab` title (`PreferencesView.swift:1092`). The orphaned `@AppStorage` properties in `PreferencesView.swift:30-34` stay until D2a (they are harmless and keep the diff focused).
4. **Strings:** apply the full Q1 string table (menu bar, toolbar, help texts, preview title).
5. **Docs:** README sections `:101`, `:118-145` rewritten around the Quota Meter; CHANGELOG bullets: Cockpit modes retired, View menu now a single Quota Meter toggle, Cmd+Shift+M removed, Cmd+Opt+Shift+C now toggles visibility.

Verification gate: build + full suite + manual QA — prime defaults to `full`, launch, confirm the QM (not an empty or full-chrome window) appears at a sane default size; repeat primed to `compact`; confirm View menu shows the single toggle with working shortcut and checkmark; confirm menu-bar extra strings; confirm Settings tab shows no Compact/Full sections. **Stop-and-report clause:** if the primed-`.full` launch produces any wrong-chrome or wrong-size window state, stop — do not patch the window configurator ad hoc in this phase; that work belongs to D2b where it gets its own review.

Suggested commit: `feat(quota-meter): retire Compact and Full Cockpit modes, single View-menu toggle` with `Why:` trailer.

### Phase D2a — Dead-code sweep, view layer

1. Delete `AgentCockpitHUDRowView.swift` and `AgentCockpitHUDGroupHeader.swift`; remove both from `project.pbxproj` (file reference + build file), then `xcodebuild -resolvePackageDependencies` + build per `agents.md`.
2. Delete `AgentCockpitHUDDisplayMode` and all readers; `AgentCockpitHUDDerivedStateModel` gets `initialCompact: true` semantics (`AgentCockpitHUDView.swift:871`, `derivedState.setCompact` call `:1000`).
3. Apply the Q5 symbol inventory for `AgentCockpitHUDView.swift`. **Sweep rule:** work outside-in, compiler-driven — delete the known-dead entry points first (`bodyList`, header branches, `HUDLimitsBar`, shortcuts, context menu), then delete whatever the compiler proves newly unreferenced, and stop at the row/presentation pipeline: `makePresentationState` (`:1947`), `HUDRow` production, `liveSessionSummary` (`:2346-2369`, menu-bar consumer at `StatusItemController.swift:222-228`), `showProbeSessionsInHUD` filtering, and everything `HUDLimitsRowsPanel`/`HUDRunwayPanel` touch are load-bearing and must not be restructured in this phase. Prune `HUDPresentationState` fields (`groupedVisibleRows`, `shortcutIndexMap`, `visibleRows`, `fullListLayoutSignature`, `renderedRows`) only where the compiler confirms no consumer.
4. Onboarding: drop the two mode writes (`OnboardingListTopSlot.swift:208-212`); delete orphaned `@AppStorage` in `PreferencesView.swift:30-34` and the Cockpit key constants removed by Q4.
5. Add the UserDefaults cleanup sweep (Q4) to the shared launch bootstrap + its unit test.
6. Update/delete tests per Q7's symbol rule.

Verification gate: build + full suite; grep gate — `rg -n "\.full|\.compact" AgentSessions/Views/AgentCockpitHUDView.swift` shows no display-mode remnants; manual QA — QM renders identically to D1 (rows, runway, chrome modes, pin, enlarged, popovers, Cmd+W), menu-bar Live Sessions counts still correct (they run through `liveSessionSummary`).

### Phase D2b — Window machinery collapse (the risky one)

This phase touches the QM window's styling/sizing path — the window with two rolled-back interaction changes (hover-resize 2026-07-06; hover-expansion, which broke background dragging). It changes no geometry rules on purpose; it removes now-unreachable branches.

1. Apply the Q5 inventory for `AgentCockpitHUDWindow.swift`; shrink `StyleInputs` and the configurator call site (`AgentCockpitHUDView.swift:1100-1112`).
2. Preserve byte-for-byte the limits-path behaviors: chrome strip (`applyCompactChrome`), `isMovableByWindowBackground = true` (`:244`), resize increments (`:248-253`), min/max width hug (`:269-274`), pin block (`:354-363`), autosave name `"AgentCockpitHUDWindow.limits"`, grow/shrink anchoring (`HUDLimitsResizeAnchor`).

Verification gate: build + full suite, then a dedicated manual QA pass on the QM window: drag from background; pin/unpin (level and spaces behavior restored on unpin); chrome Always/On hover/On demand each show and hide without any window movement; Enlarged toggle resizes once and hugs width; toolbar reveal grows/shrinks anchored to the correct edge; quit and relaunch restores position; Cmd+W closes. **Stop-and-report clause:** any observed change in drag behavior, window jumping, or resize anchoring — stop immediately, report with a before/after description, do not iterate on geometry in place (that is exactly the failure mode of the two rollbacks). Runtime `setFrame` tracing is the sanctioned diagnostic if sizing misbehaves.

### Phase F-A — Focus service (feature 1, step A)

Per spec "Design" and "Call sites"; targets only the main session list plus a reusable resolver.

1. New file `AgentSessions/Services/SessionFocusService.swift` (added via `scripts/xcode_add_file.rb` to the AgentSessions target; test file likewise to AgentSessionsTests): `FocusCapability` enum (`.itermTab`, `.desktopApp`, `.terminalApp`, `.transcript` — no `.none`), pure resolver with injected running-application lookup, executor (`tryFocusITerm2` branch unchanged; `NSRunningApplication` matched by bundle id then `activate()`; `.transcript` via existing navigation). Never launch, never trigger Automation consent; any failure falls through to `.transcript` (spec "Graceful degradation").
2. `TerminalKind` universal fallback (`Services/TerminalKind.swift:12-27`): expose the raw `__CFBundleIdentifier` for activation when the kind is `.unknown`; precedence bundle-id first, `TERM_PROGRAM` second. Named cases for Ghostty/WezTerm/Kitty/Alacritty only if a `displayName` is actually rendered — default is skip (spec "TerminalKind").
3. Desktop mapping by bundle id only: Codex → `com.openai.codex` (ships inside ChatGPT.app), Claude → `com.anthropic.claudefordesktop` (spec "Verified findings" 2).
4. Rewire `UnifiedSessionsView`: `terminalFocusAvailability` (`:3018-3038`) resolves a capability; `focusActiveTerminal` (`:3040-3059`) executes it. The `:3033` help string becomes capability-dependent (the one user-facing string change of this phase). In the main list the `.transcript` capability means "this row's home is right here": the focus affordance is shown only for the three live capabilities; a log-only session keeps its normal row behavior and no dead focus button. The existing failure alert (`:3059`) disappears — failures fall through silently per spec ("no error UI").
5. `canAttemptITerm2Focus` (`Services/CodexActiveSessionsModel.swift:1730`) keeps name and behavior as the resolver's iTerm branch. After D2a its only other caller is dead `CockpitView.swift` — untouched.
6. Unit tests per Q7.

Verification gate: build + suite; manual QA on the main list — iTerm2 session lands on the exact tab (unchanged); a Terminal.app/Ghostty session focuses that app; an unlisted terminal focuses via fallback; a dead session's row shows no focus affordance; help strings match capability. CHANGELOG bullet.

### Phase F-C — Desktop detection (feature 1, step C)

Per spec "Detection prerequisite" and "Codex desktop holds several sessions per process" (Option B decided).

1. Gate A (`Services/PresenceEngine.swift:1053`, `:1063`, `:1073`): admit tty-less PIDs for desktop-app command paths.
2. Gate B (`Services/CodexActiveSessionsModel.swift:3151`): `(v.tty != nil && (v.sessionLogPath != nil || v.cwd != nil)) || v.sessionLogPath != nil`.
3. Codex desktop: keep lowest-FD single row (`:3136`) — Option B, no row-count change. The possibly stale label is a known, accepted labeling bug (spec decision, 2026-07-20).
4. Claude Desktop: cwd+recency correlation (`PresenceEngine.swift:1173-1180`) already works once Gate A admits the PIDs; add the Electron-main-process falls-out test.
5. Respect the load-bearing risks: `coalescePresencesByTTY` (`CodexActiveSessionsModel.swift:741`) tty-less bucket gets regression tests; the relaxed prefilter increases `lsof` traffic per refresh — measure a refresh cycle before/after (the presence pipeline has a documented perf-regression history; if idle cost visibly rises, use the PerfBench harness before shipping, never computer-use).
6. Update `PresenceEngineRegressionTests` expectations deliberately, with each diff justified in the commit body.

Verification gate: build + suite; manual QA with Codex desktop and Claude Desktop running — desktop rows appear in the main session list and clicking focuses the right app (F-A already landed, so no dead clicks — this is why C must not ship before A); no duplicate rows for tty sessions; refresh cost comparable. CHANGELOG bullet. **C must not ship without B following** in the same release train for the QM surface (spec "C must not ship alone" applies to the QM's inert rows; the main list is already live after F-A).

### Phase F-B — QM row interaction (feature 1, step B)

The abortable phase, last by design. Targets `HUDRunwayPanel.runwayRow` (`AgentCockpitHUDView.swift:5315` region) and `summaryRow` (`:5338` region).

1. **Drag shim** exactly per spec pseudocode: `mouseDown` stores the event and takes no action; `mouseDragged` beyond ~4pt hands off via `performDrag(with:)`; `mouseUp` without drag activates the row. Implemented as an `NSViewRepresentable` overlay per row; the warning precedent about `mouseDown` killing `mouseDownCanMoveWindow` is documented at `AgentCockpitHUDView.swift:3729-3731` (`RightClickView`).
2. **Hover affordance:** pointing-hand cursor + faint tint via `NSTrackingArea`; identical frame hovered/unhovered; no geometry change of any kind (doctrine: `CodexStatus/UsageDisplayMode.swift:104-117`; rollback history in Part I risks).
3. **Row → destination:** `RunwayPauseImpactRow.id == RunwaySessionIdentity.id` with `logPaths` (`CodexStatus/CodexRunwayModel.swift:340`, `:224`); live presence match → resolver (F-A); no presence → `SessionLookupIndexes.byLogPath` (`AgentCockpitHUDView.swift:302-306`) → `goToSession` (`:2259`). No error UI anywhere; unresolvable rows fall to `.transcript`, and a row resolving to nothing at all is not rendered as a session row (spec).
4. **Aggregate row** `+N sessions`: click opens the fuller view. Post-deprecation the fuller view is the main Agent Sessions window — `AppWindowRouter.showAgentSessionsWindow()`. No unfold-in-place (explicitly rejected in spec).
5. Accept knowingly: app-activation z-order and repeat-click flicker residues (spec "Why the rule is shaped this way"); Spaces switching on click is intended.
6. Unit tests: destination mapping and aggregate action as pure functions. Manual QA: the spec's full Acceptance list, plus drag from **both** a session row and the background.

Verification gate: spec Acceptance section, verbatim, plus full suite. **Stop-and-report clause (from the spec, binding):** if drag-from-a-row cannot be preserved, stop and report rather than shipping a regression. Any hover or click behavior that moves, resizes, or re-anchors the window is an automatic stop — that is the exact shape of both prior rollbacks.

### Phase F-Z — Optional, owner-approved: mechanical rename pass

Only after F-B is QA'd and merged. One commit, no logic changes: file renames (`AgentCockpitHUDView.swift` → `QuotaMeterView.swift` etc., via `git mv` + pbxproj updates + `scripts/xcode_add_file.rb` for re-adds where needed, watching its known duplicate-ref gotcha), type renames, `PreferencesTab.agentCockpit` → `.quotaMeter` (graceful `lastSelectedTab` fallback verified at `PreferencesView.swift:313-314`), `CockpitFooterView` → `SessionsFooterView`. Persisted identifiers (`"AgentCockpit"` window id, `AgentCockpitHUDWindow.limits` autosave, retained `Cockpit*` defaults keys) are **still not renamed** — they are storage formats now, and migrating them buys nothing. This phase is skippable; the program is complete without it.

### Follow-ups recorded, not scheduled

- Non-activating `NSPanel` conversion for the QM — re-evaluate immediately after F-B lands (spec "Follow-up, deliberately separate").
- Should the Quota Meter be reachable when the live-sessions beta toggle is off (Q2 item 2).
- `CockpitView.swift` deletion (pre-existing dead code, separately tracked).
- Codex desktop Option A (one row per open rollout handle, recency-gated) if the stale label is judged bad enough (spec, owner decides).
- Weekly format-check and summaries-file conventions unchanged by this program.

## Risk register

| Risk | Phase | Mitigation |
| --- | --- | --- |
| QM window regression while collapsing chrome machinery | D2b | behavior-preserve list + dedicated QA checklist + stop-and-report; no ad hoc geometry patching |
| Drag shim breaks drag-from-row (two prior rollbacks on this window) | F-B | spec's bounded blast radius (background drag survives), stop-and-report clause, QA from both drag origins |
| Migration lands a `.full` user on a broken window | D1 | repair via existing `setHUDDisplayMode` path; primed-defaults QA both ways; limits default-size fallback verified in configurator |
| Over-deletion of shared row pipeline (menu-bar counts, QM entries) | D2a | outside-in compiler-driven sweep with an explicit keep-list; menu-bar counts in QA |
| Presence-pipeline perf regression from relaxed `lsof` prefilter | F-C | before/after refresh measurement; PerfBench harness on suspicion |
| pbxproj corruption removing files | D2a, F-Z | resolve-packages + build immediately after every pbxproj edit; restore from git on failure |
| Parallel sessions sharing this worktree | all | no branch/HEAD changes, commits only on owner request, path-scoped commits |
