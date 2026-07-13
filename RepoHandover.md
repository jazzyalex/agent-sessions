## 2026-07-12 19:08 · perf-instant · Runway idle-CPU fix landed on main; strategy doc; xhigh review
status: done

**State:** perf/instant-2026-07-12 merged to main `bf403fe8` (c14be03b + auth fixes; 1,552 tests green; NOT pushed). QM-visible idle CPU 25–41% → ~11% median, runway parse weight ~75× down.

**Decided / don't redo:**
- Runway cache design: only bytes-derived artifacts cached (key = path+mtime+size); ALL now-dependent state recomputed per cycle — verified byte-identical by 4 independent reviewers. Don't "optimize" the per-call filter/finalize into the cache.
- Refuted: 0.08s filter debounce is a sound trade (not a regression); RunwayFileSignature≠SessionFileStat duplication is justified (sub-second mtime needed).
- Strategy (Marketing/STRATEGY_2026-07-12_wow-and-1k.md, untracked): NO standalone meter spinout (CodexBar/steipete 17.8k owns it), NO Tauri/Rust port; wedge = per-session burn attribution; wow = Wrapped card + shareable transcripts + Memory Inspector; growth = upstream-issue comments, awesome-claude-code #1726, homebrew-cask.

**Key files:**
- `docs/perf-2026-07-12-runway-idle-fix.md` — measurements + cache invariant
- Worktree `/Users/alexm/Repository/Codex-History-perf` still exists (merged; removable)

**Next:**
1. Before next release: CHANGELOG/summaries bullets (shimmer/Reduce-Motion is user-visible) + inline the 3 new FeatureFlags gates per agents.md policy (~10 min).
2. Optional review one-liners: Codex cache self-prune, `Value: Sendable`, shimmer `.tolerance` (15 findings filed, none blocking).
3. Push main when ready. DB migration-wipe fix runs in its own task session (task_8773aec9).
4. Careful committing in main checkout: a parallel session has uncommitted edits there (usage-auth files + pbxproj) — not this session's work.

## 2026-07-10 18:28 · usage-auth-surfacing · Unified auth surfacing + guided Fix flow across all usage meters
status: done

**State:** Shipped to `main` this session: burn-meter zombie fix `9e521e51`, then the auth-surfacing redesign `f9e476eb` (amended). Full suite green (1534). Not pushed. Live-verified in the running `.deriveddata-run` build; user re-authed Claude so meters are OAuth-live again.

**Decided / don't redo:**
- Burn-projection zombie: fix is retention-expiry ONLY (3-min), in the shared `UsageLimitProjectionTracker`. The "re-baseline on long idle" idea is UNSOUND — integer-percent Codex can't tell a slow burn from idle-then-resume (breaks pinned slow-burn tests).
- All 4 usage surfaces (footer strip, menu-bar face, menu-bar dropdown, Cockpit HUD "QM") now share `QuotaData.presentationState` (live / reconnecting / needsAction). Never render a raw `0%` for untrustworthy data.
- "QM" = the Agent Cockpit HUD in Meter mode (`HUDLimitsRowsPanel`/`Bar`/`DetailPanel`) — a separate 4th surface, easy to miss.
- Expired escalation is timer-driven (~90s), independent of poll cadence.

**Key files:**
- `Shared/Views/AuthRemediationBanner.swift` — shared banner (chip/compact/full) + guided `AuthFixView` dialog + `AuthFixWindowController`.
- `Views/CockpitFooterView.swift` — `QuotaData.presentationState`, `FooterRetryChip`, footer bg removed.
- `ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — 90s escalation one-shot timer; `refreshNow()`/credential-watch now `invalidateCache()` so `claude auth login` recovers WITHOUT relaunch.
- `Views/AgentCockpitHUDView.swift` — QM presentationState + `HUDLimitsRetryCell`.

**Next:**
1. Token-cache-invalidation recovery is logic-verified only (token currently valid) — confirm live next lapse.
2. Test-hygiene bug flagged as task_230de850: `ClaudeUsageSnapshotStoreTests` writes fixture (`deadbeef`) to the REAL `~/Library/Application Support/.../claude_usage_latest.json`, polluting the running app's cache. Fix pending in a separate session.
3. Parallel work left UNCOMMITTED in the tree (not mine): `CodexRunwayModel`, `FirstRunSetupView`, `CodexUsageParserTests` (+175), `docs/*`, `CLAUDE.md`.
4. Consider push + version bump/release notes if shipping.

## 2026-07-09 16:49 · runway-auth · Cause-aware degradation, no-CLI ladder, probe hardening + CLI-logout runway fix
status: in-progress
branch: main @ 99ab8a03 (dirty: 2 files — pre-existing untracked REDDIT_*.md, not this work)

**State in one line:** Runway-auth P1–P5 shipped to origin/main (through bf0a6a2e), 1506 tests green; owner elected to skip live 15-min confirmation + in-app QA, so deploy is gated only on version bump + release notes.

### Already decided / don't redo
- AS is a READ-ONLY usage reader — NEVER mint/refresh its own subscription token (no PKCE / in-app OAuth). Owner-cancelled (ToS/ban risk).
- No-CLI rung-1 = existing claude.ai Web API mode (ClaudeWebCookieResolver + claudeWebApiEnabled), NOT a "reopen Claude Desktop" hint (Desktop uses its own encrypted store).
- Auto-mode interactive tmux fallback is default-OFF / opt-in (behavior change — must be release-noted). Delegated refresh (CLI refreshing its OWN token) is retained.
- Don't spawn `claude`/`claude auth` in loops or relaunch spuriously (ban risk). os_log is a black box from stdout — profile via direct-binary-launch.
- ClaudeUsageStripView was dead code (deleted); live surfaces = Cockpit HUD/footer + menu bar.

### Key files
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — successAdvisory (healthy fetch always `.ok` + gentle caption), first401At debounce, captionOnly emits, cold-start fallback deferral, tmuxFallbackPermitted opt-in.
- `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` — transientReason/captionOnly, currentSource, cliPresent wiring, lastSuccessAt spinner fix, refresh-request observer.
- `AgentSessions/Shared/UsageAuthStatus.swift` + `Views/AuthRemediationBanner.swift` — Remediation.noCLILadder + Web-API/install alert.
- `AgentSessions/Resources/claude_usage_capture.sh` — auth-check-before-send-keys + BROWSER suppression (symlinked to tools/).
- Root-cause anchor: `AgentSessions/Views/AgentCockpitHUDView.swift:4945` — HUD blanks meters on ANY alarming verdict (no freshness check).

### Verified
- 1506 tests, 0 failures (full suite, 2026-07-09). All runway commits on origin/main; HEAD 99ab8a03, 0 unpushed.
- OAuth usage API returns HTTP 200 with the valid keychain token (~8h left, refresh token present).
- QM works with CLI logged out on the fixed build (user-confirmed — right after relaunch).

### Believed / unverified
- The runway fix HOLDS past the ~15-min reprobe mark — argued from code/tests, NOT a long live run. Owner accepted this as risk (skipped).
- No-Safari probe path, no-CLI ladder alert, opt-in toggle not owner-QA'd in-app (ladder proven via a DEBUG test seam). Owner accepted as risk (skipped).

### Next steps (prioritized)
1. DECIDE: version bump (still 4.2 / build 55) + user-facing release notes (default-OFF fallback is a behavior change) via the release-notes skill.
2. DECIDE: confirm the release intentionally bundles other sessions' work (transcript-selection fix, handover skill) or cut a scoped release.
3. Deploy via the `deploy` skill (re-runs QA via the stamp).
4. Optional (deferred, owner may skip): 15-min live confirmation / stub `{"loggedIn":false}` repro; diagnostics-pane observability (currentAuthState + cliStatusCache age); the 2 low review findings.

### Risks / landmines
- Deploy would ship other sessions' work too (transcript-selection fix, handover skill) — confirm intended for this release.
- os_log uncapturable from stdout — diagnose OAuth via direct-binary-launch or add a diagnostics ring buffer.
- Runway fix's post-15-min behavior is unproven live (accepted risk) — if runway ever blanks again, the anchor is the HUD render at AgentCockpitHUDView.swift:4945 + any new alarming-verdict source.

### How to verify
- `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test`
