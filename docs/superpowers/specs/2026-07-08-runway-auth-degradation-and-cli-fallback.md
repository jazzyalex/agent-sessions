# Claude Runway Auth — Graceful Degradation & Guided CLI Fallback

**Date:** 2026-07-08
**Status:** Draft for owner review (spec only — no code changes)
**Supersedes:** the "AS-owned OAuth self-refresh (PKCE)" direction previously drafted in this
file. **That direction is cancelled — see §1.** Builds on shipped Phase 1
(`docs/superpowers/specs/2026-07-07-runway-auth-health-design.md`) and the cold-start
fallback fix (commit `84fc9696`).

> Renamed 2026-07-08 from `2026-07-08-reauth-and-as-owned-refresh-design.md` — the original
> title predated the §1 decision to cancel AS-owned OAuth.

---

## 1. Decision: no in-app token minting, ever

Agent Sessions will **never** mint or refresh its own Claude subscription token. No PKCE
login, no loopback OAuth, no refresh-token grant against any store (including the CLI's).

Rationale: obtaining a subscription (non-API) token from a third-party app requires reusing
the official client's identity — impersonation — which is a ToS violation and concentrates
ban risk across **every user** of a shipping product. **AS is a read-only *reader* of usage,
not an *authenticator*.** It reads whatever access token the official Claude tooling already
minted (CLI keychain / env / creds file), calls only the read-only `GET /api/oauth/usage`,
and never performs inference. (One nuance: AS may trigger the **official CLI** to refresh its
*own* token — a "delegated refresh" that spawns the non-interactive, browser-suppressed
`claude auth status` so Claude Code performs its own refresh-token grant — then re-reads the
result. That is the official client refreshing itself, consistent with this rule; AS itself
never runs a refresh grant with a token it read, and never mints a new session.) When those
tokens go stale and no official tool refreshes them, AS **surfaces the condition and guides the
user** — it does not paper over it.

Consequence, stated plainly: because AS won't refresh tokens itself, a **no-CLI Desktop user
whose token goes stale has no in-app fix.** The rest of this spec is how AS behaves honestly
and helpfully in exactly that case.

## 2. Goal & non-goals

**Goal:** when the OAuth usage path stops working, tell the user **why** and **what to do** —
distinguishing a **transient** outage (self-heals in minutes/hours; don't alarm) from a
**genuine** auth-expiry (action needed). For no-CLI users, offer a zero-install remedy first,
then an **opt-in** guided CLI install so AS can fall back to the gated CLI probe.

**Non-goals:** no token minting/refresh (§1); no inference; no surprise browser from any path;
no changes to usage-meter math, poll cadence, or the Codex side.

## 3. Cause-aware failure classification

`performOAuthFetch` already separates `unauthorized` (401) from other errors and carries
`was401` into `classifyAndPublishAuthState`. Extend the **presentation** (not the
never-false-alarm classifier rules) to distinguish three causes:

| Cause | Signal | State / health | User sees | Offer CLI? |
|---|---|---|---|---|
| **Transient service / network** | 5xx, `URLError`, timeout, empty payload | stays `.ok`/`.unknown`; snapshot `health` → `.stale`/`.degraded` + reason | Calm inline: "Claude usage temporarily unavailable — usually a Claude service issue, restoring on its own. Retrying." | No |
| **Rate limited** | 429 (`.rateLimited`) | unchanged (existing backoff) | "Rate-limited — retrying shortly." | No |
| **Session expired** | 401 **persistent** (debounced per Phase 1) | `.expired` → remediation banner | cause-aware copy + remediation ladder (§5) | Yes (no-CLI) |

Key: transient failures **never** raise the remediation banner or the install offer — they use
a non-alarming "temporarily unavailable / retrying" presentation and auto-clear on the next
good fetch. Only a **persistent, debounced 401** escalates. This is the "sometimes it's a
Claude service hiccup, restores in minutes/hours" case the owner called out.

## 4. Degradation presentation

- Non-alarming transient presentation: reuse `ClaudeLimitSnapshot.health` (`.degraded`/`.stale`)
  plus a short reason string surfaced in strip / menu / Cockpit — **no new `UsageAuthState`,
  no banner, no notification.**
- Escalate to `.expired` only after a 401 **persists past a threshold** (TO CONFIRM: ~N minutes
  / M consecutive 401 polls) so a short outage stays calm.
- Recovery is automatic and silent: a subsequent 200 clears the reason and restores `.live`
  (existing success path — no user action).

## 5. Remediation UX (only on genuine expiry)

Reuse shipped machinery unchanged: `UsageAuthState`/`UsageAuthStatus`, `AuthRemediationBanner`,
one-shot `AuthStatusNotifier`. **No PKCE, no in-app sign-in button.** Remediation is a *ladder*,
chosen by `CLIBinaryPresence`:

- **CLI present:** existing copy-command chip → `claude auth login` (refreshes the CLI's token,
  which AS then reads). Unchanged.
- **No CLI (Desktop-only) — the hole this spec fills:** two-rung offer in the banner:
  1. **Zero-install (Web API mode):** "Sign in at claude.ai, then enable Web API mode." AS
     already ships a claude.ai session-cookie path (`ClaudeWebCookieResolver` + the
     `claudeWebApiEnabled` pref) that needs no CLI — this is the honest zero-install remedy for
     Desktop-only users. *(Rejected alternative: "reopen Claude Desktop" — Desktop is an Electron
     app with its own encrypted store ("Claude Safe Storage"), not the CLI's
     `Claude Code-credentials` item, and a claude.ai relogin refreshes the cookies the Web API
     path uses, not the OAuth token AS reads. So the cookie/Web-API path is the real zero-install
     route.)*
  2. **Opt-in guided CLI install:** "Install the Claude CLI so Agent Sessions can fetch usage
     directly." Presents a help sheet with the `brew install …` / npm command + a **Copy**
     button — mirrors the existing "tmux not found → Copy brew command" alert in
     `ClaudeUsageStripView`. AS **guides only**; it never auto-runs an installer. After install
     + `claude auth login`, `CLIBinaryPresence` detects the CLI and the gated probe (§6) becomes
     available.

Banner appears only on debounced `.expired` / `.signedOut` / (`.cliNotInstalled` && no usable
token). `AuthStatusNotifier` fires once per episode; `.ok` resets it. Layout/spacing per
`agents.md` HIG — no new visual language.

## 6. CLI probe — gated last resort, hardened UI

The interactive tmux `/usage` probe stays as a **last resort**, not a primary path, with three
hardening rules:

- **Never surprise-launch a browser.** The existing auth gates on both the auto fallback
  (`ClaudeUsageSourceManager.activateTmuxFallback`) and the manual hard probe
  (`ClaudeUsageModel.hardProbeNowDiagnostics`) stay; **additionally**, if a signed-in probe
  would still require an interactive login, **abort and show the banner** instead of opening
  Safari. This closes the residual hole behind the cold-start bug.
- **Honest labeling.** Surface when QM data comes from the **CLI fallback** vs the OAuth
  endpoint (`ClaudeUsageSource` already distinguishes `.tmuxUsage` from `.oauthEndpoint` — add a
  source badge in strip / menu / Cockpit). The manual double-click hard probe gets a clearer
  affordance/tooltip.
- **Retained soft probes:** non-interactive `claude auth status` (`CLIAuthStatusProbe`,
  throttled 15 min) and `claude --version` (UA string) are unchanged — no browser, low cost.

## 7. Precedence & what does NOT change

Token precedence is unchanged from today: **env `CLAUDE_CODE_OAUTH_TOKEN` → CLI keychain
(`Claude Code-credentials`) → `~/.claude/.credentials.json`.** No AS-owned source. Read-only
`usage` endpoint only. The cold-start fix (`84fc9696`), the Phase-1 classifiers / banners /
notifier, usage-meter math, and poll cadence are all unchanged.

## 8. Risks & open questions

- **Resolved (was the open question):** Claude Desktop does *not* refresh a token AS can read
  (its own encrypted Electron store), so §5 rung 1 uses the existing claude.ai **Web API cookie
  path** instead. Remaining check: confirm that shipped `claudeWebApiEnabled` path still works as
  a Desktop-only remedy (it already exists — this is validation, not new auth surface).
- **Read-only subscription-token use remains a ToS gray area** even without minting. Keep it
  minimal — read-only `usage` only, never inference — and be ready to gate behind a
  setting/disclosure if Anthropic signals objection.
- **Ban / dev hygiene (owner-flagged):** keep CLI spawns minimal and non-interactive-safe; no
  live-auth loops in dev/CI; the interactive probe must be able to **decline** rather than open
  Safari.
- **Transient→expired threshold** (§4) needs tuning: don't alarm during an outage, don't hide a
  real expiry too long.

## 9. Phasing

- **P1 — cold-start fallback fix.** ✅ DONE (commit `84fc9696`).
- **P2 — cause-aware degradation.** Distinguish transient / 429 / expired; calm "temporarily
  unavailable" presentation; escalation threshold; silent recovery.
- **P3 — no-CLI remediation ladder.** Zero-install hint (only if §8 confirms it works) +
  opt-in guided CLI-install sheet; `.cliNotInstalled` copy drops "(coming soon)".
- **P4 — harden the probe.** Abort-instead-of-browser; CLI-fallback source labeling; the
  interactive auto-mode fallback becomes **default-OFF / opt-in** (a pref; release-noted, since
  auto-mode users with persistently-failing OAuth lose their last-resort data path).

**Cancelled — do not build:** AS-owned Keychain item, PKCE login flow, in-app token refresh,
`Remediation.inAppSignIn`. Tests follow the Phase-1 pattern (pure, table-driven, no live auth
calls); new Swift files via `scripts/xcode_add_file.rb`; commits per `agents.md`.
