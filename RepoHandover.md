## 2026-07-18 12:31 · site-chrome-unification · Landing header + style unified across guides & blog
status: done

**State:** Guides and The Rollout blog now use the landing page's sticky nav header, design tokens, and full light+dark mode. Committed `6f0c96ec`, pushed to `main`, GitHub Pages built (no errors), verified live on blog + guides.

**Decided / don't redo:**
- Chose Approach A (rework the shared stylesheet + swap header markup); rejected Approach B (Jekyll-ify the 6 static guides + extract landing CSS) as out of scope.
- Accepted trade-off: design tokens are duplicated between `docs/index.html` (inline `<style>`) and `guides/guide.css` — a future landing redesign needs a matching `guide.css` edit. Kept to hold zero risk on the landing page. Landing page + `guide.js` intentionally untouched.
- Sub-page nav is the **simplified** variant (brand + The Rollout + GitHub★), reusing `guide.js`'s `#github-stars` IDs — not the landing's full nav.
- Local `jekyll build` needs `LANG=en_US.UTF-8` (theme-injected `style.scss` trips US-ASCII); pre-existing, non-issue on Pages.

**Key files:**
- `docs/guides/guide.css` — now the shared design system (tokens + `.nav` + tokenized body + footer band).
- `docs/blog/blog.css` — trimmed to blog-only rules; bespoke dark-mode block removed (global via tokens).
- `docs/_layouts/blog.html` + `docs/guides/*.html` ×6 — header swapped to unified `.nav`.
- `docs/superpowers/specs/2026-07-18-site-chrome-unification-design.md` — design record.

**Next:**
1. Nothing required — shipped. Optional future: fully DRY the landing/guide tokens (Approach B) if the site gets a bigger redesign.

## 2026-07-18 10:59 · agent-support-format-check · Weekly format check (Claude mode event) + OpenClaw auth wall
status: done

**State:** Weekly `agent_watch.py` check done and committed+pushed (`b65aa748` format-check, `21a8738b` handover) — Claude went high/format_drift_detected → medium. OpenClaw is the one open item: session **format verified drift-free**, but version pin stays at 2026.6.11 (can't mint a fresh sample — auth wall). Full suite green (1650/0). Blog drafts from the earlier session are already committed+pushed (`38225903`); the flagship still needs the rewrite (see Next).

**Decided / don't redo:**
- Claude 2.1.211 `mode` event ({type,mode,sessionId}, mode=normal, 3638×) is **non-breaking** — resolves to `.meta` via the `SessionEventKind.from` fallback. Pinned by `testClaudeSchemaDriftModeEventSurvivesParsing`. Not a hotfix; already-shipped 4.6 handles it.
- Prebump is **blind to interactive-only event families** (`mode`) — one-shot `-p` never emits them; trust the weekly scan for those. Recorded in ledger/tracking.
- OpenClaw `refresh_token_reused` is NOT a sandbox artifact — a real `openclaw agent --local` fails too. Its OpenAI token store (`openclaw-agent.sqlite`) is separate from Codex's and its token is dead. Fix is **user-side re-auth** of OpenClaw's openai provider (or static `OPENAI_API_KEY`) — don't retry-thrash, don't chase the gateway.
- **`openclaw update` bricked the gateway** (Memory Core legacy→canonical index migration conflict); `doctor --fix` did NOT clear it. User doesn't use the gateway — left **stopped/quiesced** on purpose. Don't run `openclaw update` casually.
- Corrected stale metadata: matrix+ledger said 4.3.2 though app shipped 4.6 → set to 4.6.
- Also used the existing `skills/agent-session-format-check` + `agent_watch.py` — don't hand-roll a session parser (I did once this session; wasteful).

**Key files:**
- `docs/agent-support/{agent-support-matrix.yml,agent-support-ledger.yml}`, `docs/agent-json-tracking.md` — verified-version records (append-only ledger).
- `Resources/Fixtures/stage0/agents/claude/{small,schema_drift}.jsonl` + `AgentSessionsTests/Stage0GoldenFixturesTests.swift` — `mode` fixture + test.
- `docs/_posts/2026-07-14-how-coding-agents-remember.md` + 3 sibling Rollout drafts — committed but flagship needs rewrite.

**Next:**
1. (Optional) OpenClaw version-pin bump to 2026.7.1: user re-auths OpenClaw openai provider → `openclaw agent --local --agent main -m hi` → weekly scan → bump matrix/ledger/tracking. Format itself already verified.
2. Rewrite the flagship blog post (9 agents incl. Antigravity protobuf + Qwen/Factory; three storage philosophies; refresh stale Codex 126→136 KB number; "withdrawal of legibility" thesis).
3. Correct the model-field claim in the published `2026-07-11-where-agents-store-history.md` (Claude DOES write per-event `message.model`) — task chip still open.

## 2026-07-16 22:54 · claude-auth-idle-webapi · Calm idle-token QM state + Web API FDA fix
status: done

**State:** All committed on `main`: idle-token state `3e170854`, Web API cause-aware path `8076b058`, Debug signing `6160a591`, Opus review fixes `0c9457a8`. App relaunched from `.deriveddata-manual` (now Apple Development-signed). Full test suite green. Only user step left: one-time FDA re-grant to the debug app, then "Test Web API" in Preferences → Usage Tracking.

**Decided / don't redo:**
- QM "Claude auth expired" after ~24h inactivity is a routine token lapse → new non-alarming `UsageAuthState.idle` ("no active session" moon cells); alarm only if CLI reports signed-out or a *fresh* token still 401s (per-episode token fingerprint).
- `claude auth status` (CLI 2.1.207) does NOT refresh tokens — the delegated-refresh assumption is false; only a real Claude session refreshes the keychain token. AS-owned token refresh stays cancelled (2026-07-08 spec §1).
- Web API path was dead from TCC: app can't read Safari Cookies.binarycookies without Full Disk Access, and ad-hoc Debug signing invalidated FDA grants on every rebuild (cdhash-pinned). Debug now signs with Apple Development (team 24NDRU35WD) → grants survive rebuilds.

**Key files:**
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — idle publication + web fetch loop
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeWebCookieResolver.swift` — typed ReadOutcome (.permissionDenied/.noSession)
- `AgentSessions/Views/Preferences/PreferencesView+Usage.swift` — "Test Web API" self-test callout

**Next:**
1. User: remove stale FDA rows, add `.deriveddata-manual/.../AgentSessions.app`, restart, run "Test Web API".
2. Visual QA of the idle state happens at the next natural token lapse (~1 day without Claude sessions).
3. Consider Safari Profiles limitation (non-default profile login reads as .noSession) if users report false "no session".

## 2026-07-16 22:37 · release-4.6 · Ship 4.6 (Claude paste-a-cookie usage) + app-staple notarization fix
status: done

**State:** 4.6 fully deployed, verified, and announced. `main` level with `origin/main`; GitHub Release, appcast (4.6), and Homebrew cask all live. Issue #50 closed.

**What shipped:** Headline = paste-a-cookie Claude web usage (already coded pre-session). This session's real work = committing the uncommitted **app-staple notarization fix** (Info.plist `CFBundleExecutable`/`CFBundlePackageType`; build script now notarizes+staples the .app *then* the DMG — 2x notary submissions, normal not a hang) and running the deploy. First release carrying that fix.

**Decided / don't redo:**
- Manual smoke was **skipped** per owner ("deploy anyway"); automated gates (build, 1649 tests, 116 py release tests, no warnings) were GO. Notary auth comes from ignored `tools/release/.env` (App Store Connect API key) — not env vars in the shell.
- Verified the fix end-to-end on the shipped DMG: `stapler validate` passes on the app *inside* the DMG + on the DMG; `spctl --assess --type execute` → "accepted / Notarized Developer ID". This is the #50 diagnostic.

**Next:**
1. Nothing required — release done. Watch for any @efenex reply on #50 (closed; they can reopen). Optional post-release: Sparkle auto-update + `brew upgrade` smoke on a clean machine.

## 2026-07-16 17:58 · qm-lens-highlight-recurring-hint · QM recurring right-click hint + active-lens underline
status: done

**State:** Both QM UX fixes implemented, build green, 2 enum tests pass, app relaunched for QA. Uncommitted on `main`.
1. On-Demand chrome: `Right-click for controls` hint no longer retires — recurs on every hover (right-click is the only route back to the toolbar). 2. Agent row underlines the `5h`/`Wk` symbol matching the active runway lens (subtle grey, 1pt, symbol-only — not the `: `); token/$ underline neither; picked-but-absent window underlines nothing.

**Decided / don't redo:**
- Rejected a hover reveal *button* (drag-target fight) — kept right-click + recurring text hint. Underline chosen over a separate lens badge (owner: reuse existing `5h:/Wk:` labels, no new chrome). Final underline style: grey `.secondary.opacity(0.6)`, symbol-only, NOT bright accent (walked back from accent 1.5pt).
- Removed dead `quotaMeterChromeRevealedOnce` plumbing entirely (AppStorage + PreferencesKey + reset + `retired`/`hintRetired` params).

**Key files:**
- `AgentSessions/CodexStatus/UsageDisplayMode.swift` — `QuotaMeterChrome.showsRightClickHint`/`armsDwellTimer` (params dropped)
- `AgentSessions/Views/AgentCockpitHUDView.swift` — file-scope `RunwayLensWindow`/`activeRunwayLensWindow`/`runwayLensLabel`; applied at 6 label sites (`HUDLimitsProviderText` aligned+nonaligned+bottleneck, `HUDLimitsDetailPanel.detailRow`)
- `docs/superpowers/specs/2026-07-16-qm-lens-highlight-recurring-hint-design.md` — spec

**Next:**
1. Owner visual QA (both compact + Full cockpit); then commit when asked.

## 2026-07-16 17:49 · repo-triage-automation · Daily GitHub triage tool (built, right-sized, live)
status: done

**State:** `tools/triage/` shipped + installed as a daily 08:00 LaunchAgent: gathers open issues/PRs/comments + recent releases via `gh` → drafts a digest + suggested replies with a TOOL-LESS `claude -p` (data inlined in the prompt, replies parsed from stdout) → macOS notification. You skim `out/<date>/digest.md` and post with `reply.sh <id>` (shows text, y/N). Full suite green (7 files); real-claude confinement gate 9/9; verified end-to-end THROUGH launchd. Pushed to origin/main through `626dfbe6`. Posted R2 live on homebrew-agent-sessions#3.

**Decided / don't redo:**
- Flag-based agent confinement (`--allowed/--disallowedTools`) is a pre-approval list, NOT a sandbox — proven inadequate (reads/writes outside not blocked; Task/Agent/Skill still available → injection could spawn an unrestricted subagent). Fix = the TOOL-LESS architecture; do NOT reintroduce file-tool scoping.
- Right-sized from an over-engineered build: cut auto-ack tier + guardrails, apply.sh tiers, lock, status.json/catch-up, retention, idempotency ledger, state.json. Keep it minimal for a tool the user approves everything on. (memory: feedback_right_size_personal_tools)
- launchd runs a bare PATH and `claude` is in `~/.local/bin` — install.sh bakes resolved tool dirs into the plist PATH. Always verify installed jobs by triggering THROUGH launchd, not just manually.

**Key files:**
- `tools/triage/README.md` — how it works + install/use; `run-agent.sh` — tool-less agent + stdout delimiter parse; `reply.sh` — hardened manual post path
- `docs/superpowers/specs/2026-07-16-repo-triage-automation-design.md` — design + security findings (right-sized banner)

**Next:**
1. Nothing required — runs tomorrow 08:00; skim the digest, `reply.sh <id>` as needed. Uninstall: `bash tools/triage/uninstall.sh`.
2. Product (not tool): issue #50 (notarization) still open — confirm whether v4.5 contains the stapling fix, then close the loop with the reporter.

## 2026-07-16 14:34 · claude-web-manual-cookie · Claude web usage via pasted session cookie
status: done

**State:** Paste-a-cookie Claude web usage shipped and owner-QA-confirmed working (Settings → Usage Tracking → Data source "Web API only" → paste sessionKey → Test now = "Working"). Committed to local `main` (`33fcda27` feature + `95e73b43` review fixes), NOT pushed. Full suite 1649 pass.

**Decided / don't redo:**
- Root cause proven on-machine: claude.ai `sessionKey` is NOT in any readable binarycookies file on modern Safari; path-fix / SweetCookieKit can't rescue Safari. Chose SAFE MANUAL COOKIE PASTE (CodexBar's actual Claude approach), NOT embedded WKWebView login (spec Plan A — rejected as heavier/riskier).
- sessionKey stored in Keychain (never plaintext UserDefaults). `extractSessionKey` is name-anchored (split on ';', match pair named exactly `sessionKey`); self-test uses `ClaudeWebUsageClient.fetch(bypassCache:)` so it validates live, not from the 3-min /tmp cache.

**Key files:**
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeManualWebCookie.swift` — extractor + Keychain store (PRIMARY web source).
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeWebCookieResolver.swift` — 7 typed outcomes + value-free diagnostics (Safari reader now legacy fallback).
- `AgentSessions/Views/Preferences/PreferencesView+Usage.swift` — paste UI + Test-now self-check.

**Next:**
1. Push when the parallel work lands (both commits are local-only on `main`).
2. Optional, deferred code-review findings: source-manager tests read real Keychain via `.shared` (non-hermetic); `save()` conflates keychain-write-fail with invalid-paste message; bare token containing `=` rejected; synchronous Keychain read on the actor.

## 2026-07-16 14:34 · claude-usage-wedge-fix · Claude usage stuck-until-relaunch + FDA flap diagnosis
status: done

**State:** 4.5 shipped/pushed earlier this session. Claude-usage fixes pushed to `origin/main` (`4d81b789`). Bug 1 (usage wedges on "no active session" for hours until relaunch) fixed + self-heals; Bug 2 (web cookie path) handled by a parallel session; FDA flap diagnosed as a dev artifact (no code).

**Decided / don't redo:**
- **Bug 1 root cause = one-shot `didAttemptDelegatedRefresh` latch** (reset only by OAuth success). Fixed by replacing with a 10-min throttle (`shouldAttemptDelegatedRefresh`/`lastDelegatedRefreshAt`), cleared on `refreshNow` (double-click QM / wake force it). Commit `6a9242a3`, mutation-verified test.
- **Bug 2** (Safari cookie path broken on macOS 14/15 — sessionKey not in the legacy binarycookies file): parallel session shipped **manual cookie paste** (`33fcda27`, `95e73b43`), NOT the embedded-WKWebView login in the spec. Spec is marked superseded.
- **FDA flap** = dev builds share bundle id `com.triada.AgentSessions` with the official app; TCC keys FDA to signature so the grant flaps. NOT a shipping bug. Do NOT do the Debug-bundle-id split — coupled to `AppRuntime.isHostedByTooling` (would disable filesystem probing in all debug builds) + hardcoded self-probe ids. Fix = build-only, don't `open` dev builds.

**Next:**
1. User: one-time FDA cleanup — remove "AgentSessions" from Full Disk Access, re-add only `/Applications/AgentSessions.app`.
2. Optional follow-ups from Codex on Bug 1: hidden-surface OAuth recovery (credential-watch never wakes OAuth) and `.expired` tmux suppression — left intact, not needed for the fix.

## 2026-07-16 11:27 · notarization-staple-50 · Fix Gatekeeper "could not verify free of malware" (issue #50)
status: in-progress

**State:** Root-caused issue #50 by inspecting the shipped 4.4/4.5 DMGs: the app is signed **and notarized** (cdhash registered), but the release only stapled the **DMG**, never the **.app** inside it → Gatekeeper does an online check at first launch that fails offline/behind proxies. Fix applied to the release pipeline + Info.plist; **uncommitted on `main`, not yet released**. Replied to reporter on GitHub with a safe workaround, promised a fixed build today.

**Decided / don't redo:**
- The app WAS notarized — proven: `stapler staple AgentSessions.app` fetches a live ticket. Do NOT resubmit from scratch; it was purely a missing staple step.
- Pipeline now notarizes+staples **both** the app zip AND the DMG → **two `notarytool` submissions per release (~2x notary wait). That's expected, not a hang.**
- Sync path (`NOTARIZE_SYNC=1`) left un-hardened on purpose: the `stapler staple` step after each notarize is the real Accepted-gate (no ticket → hard fail under `set -e`).
- Missing `CFBundleExecutable`/`CFBundlePackageType` also made code identity fall back to the bundle filename (renaming breaks cdhash) → added both to Info.plist.

**Key files (all uncommitted):**
- `tools/release/build_sign_notarize_release.sh` — new order: sign → zip → notarize → staple+validate app → DMG → notarize → staple+validate DMG.
- `tools/release/deploy-agent-sessions.sh` — smoke test now asserts `stapler validate` on BOTH the app and the DMG (covers resume paths); pipeline comment updated.
- `AgentSessions/Info.plist` — added `CFBundleExecutable`=AgentSessions, `CFBundlePackageType`=APPL.
- Reference doc for the user's *other* macOS app: scratchpad `macos-notarization-staple-check.md` (portable check).

**Next:**
1. User is doing other bug fixes, then cutting a new release today — these staple changes ride along automatically (deploy → build script). Expect the doubled notary wait.
2. After release, update issue #50 and confirm the shipped app passes `stapler validate`.

## 2026-07-14 21:21 · runway-dollar-burn · Session Runway $ burn: correct, stable, all pushed
status: in-progress

**State:** `$` burn (Phase 1+2) is complete and all pushed to `main` (`f09241b5`), suite green at 1601 — but **committed, not released**: 4.4 shipped without it, so no user has it yet. Four review passes fed it (Fable, Codex@low, /code-review, Codex@high — only the high-effort Codex pass earned its keep).

**Decided / don't redo:**
- **Route B**: price what we can, DROP what we can't; nil only when nothing is priceable. Do not revert to "any unpriced model → whole provider falls back" — that caused the $/tk flap on every 5s refresh.
- **Reasoning is already inside `output_tokens`** (verified: `total == input + output`) and is billed at the output rate. Codex@high raised subtracting it as a P1 — it's wrong; subtracting understates. Don't "fix" it.
- **`<synthetic>`** (Claude) is not a model; it carries usage but all zeros → zero-rate slice, exempt by design. Do NOT add a price key. (If Claude ever gives it real tokens, every Claude session would drop from `$`.)
- **One `>=` acceptance rule** for prices. Strict-cache (`>`) was tried and reverted: it discarded same-date corrections on relaunch. Editing `docs/prices.json` MUST advance `updated`, or clients ignore it.
- **Opus is $5/$25**, not $15/$75 (was 3x over). Fable/Mythos $10/$50 — pricier than Opus.
- Model resolution: **last** `turn_context`, not the first, via a scan frontier. Cache-first was the bug; a warm cache masked a `/model` switch.
- Sonnet 5 intro $2/$10 ends 2026-08-31 — we deliberately bundle the stable **$3/$15**. No action at expiry.

**Key files:**
- `AgentSessions/CodexStatus/CodexRunwayModel.swift` — `RunwayModelComponent` (per-model pricing), `dollarSnapshot`, model resolution + frontier cache.
- `AgentSessions/CodexStatus/RunwayPriceTable.swift` + `docs/prices.json` — must stay **identical**; Pages serves the latter to shipped apps.
- `skills/agent-session-format-check/SKILL.md` §2a — price-freshness maintenance (monthly + any model launch); the scan cannot catch price drift.

**Next:**
1. **Release it** — `$` burn is unreleased; the "your session is burning $X/h at API rates" meter is a strong release-notes story.
2. Open by choice: one unknown-model subagent drops the whole session from `$` (Codex finding #3 — fails safe, benign today since subagents run priced models).
3. Owner QA of `$` across a fan-out session (opus parent + sonnet subagents) — measured 1.13x overstatement before the per-model fix; should now read ~$28.52 not ~$32.11.

## 2026-07-14 14:19 · opencode-qm-usage · Research: OpenCode usage/limits in Quota Meter
status: in-progress

**State:** Research/eval only, no code changes. OpenCode is already first-class for history (parser + `opencode.db` SQLite reader + JSON) AND already in the QM live-session list (`supportsLiveSessionSource(.opencode)==true`; PresenceEngine discovers opencode via ps/lsof; Cockpit `supportedSources` includes `.opencode`). The ONLY missing piece vs Codex/Claude is **usage** (5h/week limits + Session Runway).

**Decided / don't redo:**
- The blocker for an opencode usage bar is the **consumption number**, NOT the runway. Codex reads logged `rate_limit` events from its own jsonl; Claude reads `api.anthropic.com/api/oauth/usage`. OpenCode exposes neither — no local window-consumption, and the Zen balance API is still an open/unscheduled request ([sst/opencode #10448](https://github.com/anomalyco/opencode/issues/10448)). CodexBar got the same ask ([#1006](https://github.com/steipete/CodexBar/issues/1006)) and closed it without shipping.
- OpenCode Go/Zen has the same window shape ($12/5h, $30/wk, $60/mo) but usage is dashboard-only. BYO-key users (the majority, incl. this repo owner — `~/.local/share/opencode/auth.json` = anthropic only) have **no window to meter at all**.
- Local message files DO carry per-msg `tokens{input,output,reasoning,cache}` + `cost` + `time`+`sessionID` (verified on disk) → a token-burn meter is computable offline. BUT observed `cost:0` on a Zen (`providerID:opencode`, `big-pickle`) msg → local cost may not populate for Go; token→$ conversion would drift. Any locally-computed bar is an ESTIMATE, not provider-authoritative like Codex/Claude — reputational risk with this accuracy-minded audience.
- Growth verdict: don't build the meter for stars. The high-leverage free move is a community post about EXISTING opencode support (history+search+resume+live sessions). Reserve the usage-meter build for when #10448 ships (then "first authoritative opencode usage tracker" is a real headline; CodexBar punted).

**Next:**
1. If pursuing: $5 Go spike to verify whether opencode writes non-zero local `cost` for Go usage — that single fact decides estimate-bar viability vs wait-for-#10448.
2. Marketing: reusable OC-outreach prompt was drafted in-chat (accurate do-not-claim block: NO opencode usage/quota/runway claims). Offer to save as `Marketing/PROMPT_opencode-outreach.md` and/or run it to produce Reddit + X drafts.
3. Parser note if building token-burn: `OpenCodeSessionParser`/`OpenCodeSqliteReader` read message PARTS, not message-level `tokens`/`cost` — that's the extension point.

## 2026-07-13 18:58 · codex-usage-window · Codex 5h-drop: length-based window routing
status: done

**State:** Shipped to main (pushed): `44339507` (main fix) + `982350ae` (follow-up); full suite green (1571). OpenAI temporarily dropped Codex's 5h window (weekly now arrives in `primary`, `secondary` null) → parsers mislabeled weekly as "5h". Now routed by `window_minutes` length (not slot) via new `CodexRateLimitWindowClassifier` across all 4 parse sites; drift guardrail; runway re-pointed to weekly when 5h absent; 3-state display (real% / "no limit" / "can't verify"). Auto-recovers when the 5h window returns.

**Decided / don't redo:**
- Route by length, NOT slot. No-length response → historical positional fallback; reset-distance deliberately unused (it broke length-less CLI-RPC fixtures).
- "can't verify" is ONLY partial drift (one good + one drifted). Fully-unplaceable response → nil → **reconnecting**, never the alarm (`982350ae` reverted the over-eager zero-window surfacing that misfired during the normal Codex connect window; length-less lone CLI-RPC window was the trigger).
- Claude "no active session" after (re)launch = transient token-refresh reconnect, NOT a regression (chased hard; keychain/signature theories were wrong; `ClaudeStatus/` unchanged since v4.3.2). Wait it out before diagnosing.
- Keep the 5h m/h "yardstick" via `RunwayProviderBaseline.windowMinutes` (default 300 → Claude untouched).

**Key files:**
- `AgentSessions/CodexStatus/CodexRateLimitWindowClassifier.swift` — shared length classifier + guardrail.
- 4 parse sites: `CodexStatusService`, `CodexCLIRPCProbe`, `CodexOAuth/CodexOAuthUsageFetcher`, `CodexRunwayModel`.
- `AgentSessions/Views/{CockpitFooterView,AgentCockpitHUDView}.swift` — display states + presentationState reconnecting guard.
- `docs/superpowers/specs/2026-07-13-codex-usage-window-classification-design.md` — design + known limitations.

**Next:**
1. Confirm the CLI-RPC `window_minutes` field name against a live `/status` RPC (currently guessed camelCase; length-less path falls through safely).
2. Optional: weekly-projection precision — thread exact-Double remaining-% through the snapshot so the ▸ run-out token fires on the weekly window (deferred; rows still render).
3. `CHANGELOG.md` [Unreleased] entry for this fix (left to owner; still uncommitted along with `RepoHandover.md`).

## 2026-07-13 18:01 · migration-corpus-guardrail · Corpus-preserving reindex primitive + guardrail
status: done

**State:** Shipped to main (pushed). Schema-migration wipe markers no longer need to nuke the FTS corpus: added `reindexSessionMeta(sources:)` that re-derives `session_meta` only, plus a guardrail comment at the marker site and `MigrationCorpusPreservationTests`. 1554 tests green. Commits: `3e549ca3` (code), `38225903` (parallel blog/spec docs), `2246d81a` (parallel perf handover).

**Decided / don't redo:**
- Scope kept deliberately minimal (owner's call): helper + guardrail test ONLY. NO rewrite of the 5 existing wipe markers (one-time, already applied — near-zero value) and NO progress UI.
- Root insight: only `session_meta` must be wiped to force a re-derive — the core indexer's "missing hydrated" supplement repopulates it. Wiping `session_search`/`session_tool_io` was pure collateral and the actual cause of "search returns nothing" after an upgrade.
- Only Claude/Codex/OpenClaw have core `session_meta` writers; the other 7 sources get meta from the search-ingest pass (reparse in place, corpus never emptied). So no source's sessions vanish after a meta-only wipe.
- Guardrail is by-example + at-site comment, NOT mechanical. A dev bypassing the primitive with a raw corpus DELETE won't trip the test — mechanical enforcement would need a typed migration registry (the refactor the owner declined).

**Key files:**
- `AgentSessions/Indexing/DB.swift` — `reindexSessionMeta` (instance + `private static` bootstrap-callable form), guardrail comment at the marker block (~L375), `rowCountForTesting` (DEBUG).
- `AgentSessionsTests/Indexing/MigrationCorpusPreservationTests.swift` — corpus-preservation contract test.

**Next:**
1. Future parse-derived `session_meta` column → add a marker that calls `try reindexSessionMeta(db, sources:)` in bootstrap; do NOT copy the old wipe markers.
2. If the corpus-wipe footgun recurs, escalate to a typed migration registry (each marker declares scope; a test asserts none wipes the corpus).

## 2026-07-13 11:33 · agent-support · 2026-07-13 weekly session-format check + subagent fixture
status: done

**State:** Committed & pushed to main as `62a4ef12` (dad7c4e7..62a4ef12). Two additive, non-breaking drifts handled; 5 verified versions bumped; 136 tests green; monitor re-run clean (codex+claude schema_matches_baseline=True, unknown_keys=[]).

**Decided / don't redo:**
- Codex 0.144.x `world_state` event → parser reads `type` from payload, resolves to `.meta` (non-breaking). In codex small.jsonl (baseline) + schema_drift.jsonl.
- Claude subagent keys (agentId/attributionAgent): did NOT sprinkle onto main small.jsonl — built an authentic subagent fixture pair under `claude/subagent/<uuid>/subagents/` + `.meta.json` sidecar, which also covers the previously-untested `ClaudeSessionParser.detectSubagentInfo`. small.jsonl reverted to pristine.
- Bumps (all fresh real-session evidence): Codex 0.142.5→0.144.3, Claude 2.1.202→2.1.207, OpenCode 1.17.13→1.17.18, Pi 0.80.3→0.80.6, Antigravity 1.0.14→1.0.16. Usage probes all healthy.
- Baseline = evidence_fixtures minus `schema_drift.jsonl`; to clear a monitor flag the new type/keys MUST be in a non-drift fixture listed in evidence_fixtures.

**Key files:**
- `skills/agent-session-format-check/SKILL.md` — the workflow source of truth
- `docs/agent-support/agent-support-matrix.yml` / `-ledger.yml`, `docs/agent-json-tracking.md` — version records
- `Resources/Fixtures/stage0/agents/claude/subagent/` — new subagent fixture trio

**Next:**
1. Nothing outstanding for this task. Follow-up triggers per SKILL.md decision matrix on next weekly run.
2. NOTE: main checkout has a parallel session's uncommitted work (Codex usage-window classification: CodexStatus/*, pbxproj, CHANGELOG.md, new CodexRateLimitWindowClassifier.swift + design spec) — NOT this session's; left untouched.

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
