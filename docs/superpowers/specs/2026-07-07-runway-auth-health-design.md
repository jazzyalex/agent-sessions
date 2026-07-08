# Runway Auth Health — Self-Healing Sign-In State + AS-Owned OAuth — Design

**Date:** 2026-07-07
**Status:** Approved (brainstormed with owner); **revised after Fable spec review** — see
Corrections Log at the end for what changed and why.
**Scope:** Codex + Claude usage/runway auth-status detection and UX. Phase 1 ships
next release; Phase 2 (AS-owned OAuth) is designed here but implemented later.

---

## Problem

Runway/usage meters (5h %, weekly %, reset times) are **account-level quota data**.
That data is **not** present in the on-disk session transcripts Agent Sessions (AS)
reads for the session list — it only exists behind each provider's authenticated
usage API. To call that API, AS needs a valid OAuth token, and today it sources that
token **exclusively from the CLI credential store**:

- Claude: env `CLAUDE_CODE_OAUTH_TOKEN` → Keychain `Claude Code-credentials` →
  `~/.claude/.credentials.json` (`ClaudeOAuthTokenResolver.swift:64-82`). Written by
  `claude auth login`.
- Codex: `~/.codex/auth.json` (`CodexOAuthCredentials.swift:23-25`). Written by
  `codex login`.

### The incident (2026-07-07)

The user was logged out of the `claude` CLI. Effects observed:

1. OAuth token resolution failed → the Claude source manager fell back to the **tmux
   `/usage` probe**, which hit the Claude Code login screen and **hung**. Orphan
   `as-cc-*` tmux probe servers were found still alive from prior days.
   (Note: on a cold start with no cached snapshot, the tmux fallback fires on failure
   **#1**, not "after 3 failures" — see `ClaudeUsageSourceManager.swift:355-359`.)
2. Both Claude **and** Codex runway went blank. Codex has no "signed out" concept at
   all (only `cliUnavailable: Bool`, `CodexStatusService.swift:153`), so it silently
   went stale. Worse, Codex's `needsProbeOverride` path auto-spawns its own tmux
   `codex /status` probe when rate limits are missing — the identical hang class,
   which the original spec did not address (`CodexStatusService.swift:2180-2199`).
3. The app never clearly told the user *what was wrong* or *what to do*.

### Two defects

1. **No self-healing / notification.** The auth-death signal is either quiet
   (Claude: a tiny red "Login required" caption with the fix buried in a hover
   tooltip, `ClaudeUsageStripView.swift:34-58`) or entirely absent (Codex). The tmux
   hang can bypass the clean verdict, so the UI often shows a vague "Usage
   unavailable" instead.
2. **Hard CLI coupling.** Runway requires CLI auth even though the sessions being
   displayed may come from **Claude Desktop / ChatGPT-Codex Desktop**, which keep
   their credentials in separate stores AS doesn't read. **Desktop-only users who
   never installed a CLI cannot get runway at all**, with no honest explanation.

---

## Goals

- Detect auth-death **authoritatively and directly**, before (and instead of) the
  hanging tmux fallback — for *both* providers.
- Never produce a **false** signed-out verdict from a transient/unreadable-keychain
  condition.
- Surface a **loud, actionable, consistent** state: what's wrong + the exact,
  verified command to fix it (copyable).
- Fire a **one-shot system notification** per signed-out episode (permission-gated,
  never prompting).
- Make **"no CLI installed"** a first-class, honestly-explained state.
- Do all of the above through a **shared, provider-agnostic auth-state model** whose
  seam lets Phase 2 (AS-owned OAuth) drop in without changing the state machine or UI.

## Non-Goals

- Phase 2 (AS-owned in-app OAuth) is **designed here but not implemented** this round.
- No change to how the session list / transcripts are read.
- No change to the usage-meter math, cadence, or the OAuth→web→tmux fallback order for
  the *success/degraded* path. We only change the *auth-failure* path.
- We will **not** prompt the user for notification permission; we only notify if
  permission is already granted.

---

## Architecture — Shared Auth-State Model (the Phase 2 seam)

New file `AgentSessions/Shared/UsageAuthStatus.swift`, published by both
`ClaudeUsageModel` and the Codex usage model:

```swift
enum UsageAuthState: Equatable {
    case ok
    case signedOut          // authoritatively not signed in (CLI status or token absent)
    case expired            // token present but authorization failing (verified 401)
    case cliNotInstalled    // no CLI present AND no other token source (Desktop-only)
    case needsSetup         // CLI present but first-run / terms prompt pending (Claude-only)
    case unknown            // cannot determine yet (e.g. keychain unreadable) — DO NOT alarm
}

enum Remediation: Equatable {
    case showCommand(String)     // rendered with a Copy button; NEVER auto-run
    case openURL(URL)            // install docs / help page
    case none
    // Phase 2 adds: case inAppSignIn  (opens AS's own OAuth flow)
}

struct UsageAuthStatus: Equatable {
    var state: UsageAuthState
    var remediation: Remediation
    var headline: String
    var detail: String
}
```

Note: `.unknown` exists specifically so an unreadable keychain or in-flight check
never masquerades as `signedOut`. Only `.signedOut`/`.expired`/`.cliNotInstalled`
drive the loud banner + notification; `.unknown` shows nothing new (keeps last state).

Presentation strings live in the status value for convenience; this is a mild smell
(copy in the state layer) accepted for Phase 1. Each provider owns a small, pure,
unit-testable **classifier** producing a `UsageAuthStatus`.

**Phase 2 seam:** when AS owns its own token, that token becomes another resolver
source and `remediation` flips to `.inAppSignIn`. Classification, published status,
banner, and notification are unchanged.

---

## Detection strategy (authoritative first)

The blocker in the original design was inferring `signedOut` from token-resolution
`nil`, which collapses "token absent" with "keychain locked / ACL denied / `security`
timed out" (`ClaudeOAuthTokenResolver.swift:103-118` discards `terminationStatus`).
Revised, layered detection:

1. **Authoritative CLI status check (preferred, when the CLI exists).**
   - Claude: `claude auth status` (verified subcommand; exits/reports signed-in vs
     out without launching a TUI — no hang, no usage cost).
   - Codex: `codex login status` (verify exact form during implementation; `codex
     doctor` is the fallback diagnostic).
   These give a definitive signed-in/out answer and are the primary signal.
2. **Token-resolution + keychain exit-code (fallback / Desktop-only).**
   - Modify `runSecurityCommand` to **return the `security` exit code**, not just
     `nil`. Treat exit **44 (`errSecItemNotFound`)** as "token truly absent"; treat
     launch failure, timeout, or other nonzero exits as **`.unknown`**, not signedOut.
   - Require **≥2 consecutive "absent" resolutions spanning ≥60s** before committing
     to `.signedOut`. A single miss stays `.unknown`.
3. **401 classification (`expired`).** Only a *verified* HTTP 401 / refresh-rejection
   from the usage call yields `.expired`. Network/decode/cooldown → existing
   degraded/stale path, never `expired`.
4. **`cliNotInstalled`.** CLI binary unresolved (`ClaudeCLIEnvironment().resolveBinary`
   / Codex equivalent) **and** no token from any source → `.cliNotInstalled`.

---

## Workstream 0 (prerequisite bug) — why do orphan sweeps miss live probes?

The original spec proposed "add an orphan sweep." **That sweep already exists** —
`CodexStatusService.cleanupOrphansOnLaunch()` and
`ClaudeStatusService.cleanupOrphansOnLaunch()` run at launch
(`AgentSessionsApp.swift:722-723`) plus hourly on visibility. Yet multi-day orphans
survived. Root-cause candidate in code: the retry cap
`tmuxCleanupMaxKillAttemptsPerLabel = 2` (`ClaudeStatusService.swift:100, 799-801`)
skips a label indefinitely after two failed `kill-server` attempts, and a hung
login-screen probe keeps its tmux server **live**, so `kill-server` alone may not
reap it; SIGKILL of `managedProbePIDs` only fires on the socketless path
(`:844-855`).

**Task (do this first, as a bug fix, not a feature):** reproduce the surviving-orphan
condition, then make the sweep escalate — when a *live* managed `as-cc-*` server
resists `kill-server`, SIGKILL its `managedProbePIDs(for: label)` and drop the
retry-cap skip for managed labels. Ship this even independent of the rest, since it's
the concrete resource leak from the incident.

---

## Phase 1 — Ship next release

### 1a. Claude — classify, stop the hang, emit recovery

- Classify per the Detection strategy; publish `UsageAuthStatus` mapped from the
  existing `ClaudeServiceAvailability` fields (no duplication).
- **Put the short-circuit guard INSIDE `activateTmuxFallback`** (not at call sites —
  there are five: `ClaudeUsageSourceManager.swift:142, 323, 355-359, 379-380,
  572-575`). If state is `.signedOut`/`.cliNotInstalled`, refuse to activate and
  return.
- If the tmux adapter is **already running** (activated for a network blip) and the
  state transitions to signed-out, call `deactivateTmuxFallback()` (`:621-627`).
- **Emit recovery:** the OAuth success branch (`:245-269`) currently calls
  `publish(snapshot)` but **never** publishes availability, so `loginRequired` can
  stick forever (latent bug). Add an `authStatus = .ok` availability emission on every
  successful fetch — this is what resets the notification episode.
- **Gate hard probes:** the strip double-click → `hardProbeNowDiagnostics`
  (`ClaudeUsageStripView.swift:74`, `ClaudeUsageModel.swift:299-354`) and the
  Preferences "probe now" button must, on `.signedOut`, show the banner instead of
  spawning a fresh `ClaudeStatusService.forceProbeNow()` (which bypasses the source
  manager and can hang).

### 1b. Codex — add the auth signal, and stop its hang too

- **Surface error cause:** change `CodexOAuthUsageFetcher.fetchUsage` (today swallows
  401/429/cooldown/network/decode all into `nil`, `CodexOAuthUsageFetcher.swift:72-115`)
  and `CodexOAuthCredentials.readFromFile` (returns `nil` for missing-file /
  malformed-JSON / empty-token alike, `:50-70`) to **result-typed** returns:
  `.ok / .unauthorized / .skippedCooldown / .transient` and `.present / .absent /
  .malformed`. Without this the classifier cannot see a 401.
- Add `CodexAuthClassifier` consuming those results + the authoritative
  `codex login status` check; publish `authStatus: UsageAuthStatus?` on the Codex
  model.
- **Short-circuit the Codex tmux `/status` probe on `.signedOut`/`.cliNotInstalled`.**
  Add the guard to `maybeProbeStatusViaTMUX` so the `needsProbeOverride` branch
  (`CodexStatusService.swift:2180-2199`) cannot spawn `runCodexStatusViaTMUX()` for a
  signed-out account — same rule as Claude 1a.

### 1c. Loud, actionable UI (both providers)

- Shared subview `AuthRemediationBanner`: headline (red/orange by severity), one-line
  detail, a **monospace command chip with a Copy button** (`claude auth login` /
  `codex login`), or for `.cliNotInstalled` an `openURL` install link instead of a
  command. No Terminal launching, no side effects (owner decision).
- Replace the tiny-caption path in `ClaudeUsageStripView.swift:34-58`; add the
  equivalent to `UsageStripView.swift` (Codex), which today renders **no** auth state.
- Mirror the state in the menu-bar dropdown.
- **Suppress/soften when another source is live.** If Claude's web fallback (valid
  claude.ai cookies, `:350-354`) or Codex's JSONL path is still delivering **fresh**
  meters while the CLI is signed out, do not cover live data with an alarming banner —
  show a subtle "CLI signed out" note instead of the full paused banner, and do not
  fire the notification.

### 1d. One-shot notification (permission-gated, new send path)

- **Do not reuse `deliver()` / `enqueueNotificationRequest`** as-is: the latter calls
  `requestAuthorization` in the `.notDetermined` case and `deliver()` plays a sound
  regardless (`CodexStatusService.swift:1308-1310, 1407-1437`). Add a **new send path**
  that first checks `getNotificationSettings().authorizationStatus == .authorized` and
  otherwise silently no-ops.
- Fire **once per signed-out episode** per provider. `signedOut` and `expired`
  transitions share **one** episode (both are "you need to re-auth"). Reset the
  episode only on `.ok`.
- **Persist `authEpisodeID` per provider in UserDefaults** so an app relaunch while
  still signed-out does not re-notify. (If we later decide relaunch *should* re-notify,
  that's a one-line change — but default is no-spam.)

### 1e. "No CLI installed" — first-class state

- `.cliNotInstalled` renders: *"Runway needs an account token. Install the Claude
  Code / Codex CLI, or (coming soon) sign in to Agent Sessions directly."* with an
  `openURL` to the install page. This is exactly the hole Phase 2 closes.

### tmuxOnly mode

In user-selected `tmuxOnly` mode the OAuth resolver never runs
(`ClaudeUsageSourceManager.swift:141-142`), so token-based classification has no
signal. Decision: **still run the authoritative `claude auth status` check** in this
mode (cheap, no TUI) and short-circuit the tmux probe on signed-out, so tmuxOnly users
get the same hang protection. If the CLI is absent, tmuxOnly simply can't work → show
`.cliNotInstalled`.

### Files touched (Phase 1)

- **New:** `AgentSessions/Shared/UsageAuthStatus.swift`,
  `AgentSessions/Shared/Views/AuthRemediationBanner.swift`,
  `AgentSessions/CodexStatus/CodexAuthClassifier.swift` (+ tests; register via
  `scripts/xcode_add_file.rb`).
- **Edit:** `ClaudeOAuthTokenResolver.swift` (surface `security` exit code),
  `ClaudeUsageSourceManager.swift` (classify, guard inside `activateTmuxFallback`,
  deactivate-on-signedout, emit `.ok` on success), `ClaudeUsageModel.swift` /
  `ClaudeUsageStripView.swift` (map to shared status, gate hard probe),
  `CodexOAuthUsageFetcher.swift` + `CodexOAuthCredentials.swift` (result-typed),
  `CodexStatusService.swift` (publish `authStatus`, short-circuit tmux probe, new
  notification path, orphan-sweep escalation), `ClaudeStatusService.swift` (orphan
  escalation), `UsageStripView.swift` + menu-bar views (banner).

---

## Phase 2 — AS-owned OAuth (design-only this round)

**Intent:** AS holds its own token independent of either CLI, so runway works for
Desktop-only users and survives CLI logout entirely.

- Per provider, AS runs a **PKCE loopback flow** (system browser →
  `http://127.0.0.1:<port>/callback`), the shape the CLIs use.
- Tokens in **AS's own Keychain items** (e.g. `com.triada.AgentSessions.claude-oauth`),
  never touching the CLI's store.
- A new resolver source sits **first** in the chain; AS refreshes on its own timer.
- Signed-out remediation becomes `.inAppSignIn`, opening the flow from the banner
  button — no CLI, no Terminal.
- Deferred open questions: per-provider client-registration / allowed-redirect
  constraints, scope minimization (usage-read only if offered), revocation/sign-out UX.

Phase 1's shared model means Phase 2 adds one resolver source + one remediation case
and **changes no UI or state-machine code.**

---

## Testing

- **Unit (pure classifiers):** Claude + `CodexAuthClassifier` table tests over
  {no file, empty/malformed file, valid token, verified-401, keychain exit-44,
  keychain timeout/other-exit, binary-absent} → expected `UsageAuthState`. The
  keychain-unreadable and timeout cases MUST map to `.unknown`, not `.signedOut`.
- **Debounce test:** one "absent" resolution → `.unknown`; two spanning ≥60s →
  `.signedOut`.
- **Short-circuit tests:** signed-out input must not invoke the tmux adapter for
  Claude (assert `activateTmuxFallback` returns without creating an adapter) **or**
  Codex (assert `runCodexStatusViaTMUX` is never called via the override path).
- **Running-adapter test:** adapter active + transition to signed-out →
  `deactivateTmuxFallback()` called.
- **Recovery test:** signed-out → successful OAuth fetch publishes `.ok` availability
  (guards the latent-bug fix).
- **Notification tests:** repeated signed-out publishes → exactly one notification;
  `.ok` then signed-out again → a second; `signedOut`↔`expired` within an episode →
  still one; relaunch while signed-out (persisted episode) → none; permission not
  `.authorized` → none, and no `requestAuthorization` call, no sound.
- **Live-data-suppression test:** signed-out CLI + fresh web/JSONL snapshot → subtle
  note, no paused banner, no notification.
- **Orphan escalation test:** a live managed `as-cc-*` server resisting `kill-server`
  → `managedProbePIDs` SIGKILLed; non-managed labels untouched.
- Full suite green before commit; owner QA at feature-complete (batch).

## Risks

- **False `signedOut`.** Mitigated by authoritative CLI status check + exit-44
  discrimination + ≥2/≥60s debounce + `.unknown` fallback. This was the review's
  blocker; the design now treats "can't tell" as its own state.
- **Command-string drift.** The codebase currently disagrees (`claude /login` in
  Swift at `ClaudeUsageSourceManager.swift:616` vs `claude login` in the script at
  `claude_usage_capture.sh:447`); both are wrong. Verified correct commands:
  **`claude auth login`** and **`codex login`**. Normalize all copies to these.
- **Copy-button only (no auto-run):** user still pastes; accepted per owner decision.
- **Web-fallback coexistence:** handled by live-data suppression (1c).

## Open questions resolved

1. Keychain discrimination + debounce window: **exit 44 = absent; else `.unknown`;
   ≥2 resolutions over ≥60s before `.signedOut`.** (was Issue 1)
2. Why orphan sweeps missed servers: **retry-cap-2 skip + live server not SIGKILLed;
   fixed in Workstream 0.** (was Issue 4)
3. `authEpisodeID` persistence: **UserDefaults per provider; no relaunch re-notify.**
   (was Issue 6)
4. Banner vs live data: **suppress/soften when web/JSONL is fresh.** (was Issue 8)
5. Remediation commands: **`claude auth login` / `codex login`.** (was Issue 9)
6. tmuxOnly: **run `claude auth status`, short-circuit tmux, else `.cliNotInstalled`.**
   (was Issue 10)
7. Hard probes gated on signed-out: **yes (1a).** (was Issue 5)

---

## Corrections Log (post-Fable-review revisions)

- **Blocker:** added `.unknown` state + authoritative `claude auth status` detection +
  `security` exit-code discrimination + debounce, so keychain-unreadable no longer
  false-fires signed-out.
- **Codex under-scoped:** added result-typed `CodexOAuthUsageFetcher` /
  `CodexOAuthCredentials` to files-touched; classifier can now see 401.
- **Codex hang:** added short-circuit for the Codex `needsProbeOverride` tmux
  `/status` probe (was entirely unaddressed).
- **Orphan sweep:** reframed from "add a sweep" (already exists) to a root-cause
  bug fix (Workstream 0).
- **Short-circuit correctness:** guard moved *inside* `activateTmuxFallback` (5 call
  sites); deactivate running adapter on signed-out; gate hard probes; corrected the
  "after 3 failures" narrative (cold start hangs on failure #1).
- **Notification:** new `.authorized`-gated send path (not the prompting/sounding
  reuse); episode persisted; signedOut↔expired share one episode; recovery `.ok`
  emission added (fixes a latent stuck-`loginRequired` bug).
- **Command strings:** corrected to `claude auth login` / `codex login`.
