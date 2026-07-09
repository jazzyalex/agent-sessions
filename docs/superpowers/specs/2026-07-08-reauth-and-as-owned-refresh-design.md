# Claude Re-Auth UX + AS-Owned OAuth Self-Refresh — Design

**Date:** 2026-07-08
**Status:** Draft for owner review (spec only — no code changes)
**Scope:** Claude runway auth. Builds on the shipped Phase 1 auth-health work
(`docs/superpowers/specs/2026-07-07-runway-auth-health-design.md`, plan
`docs/superpowers/plans/2026-07-07-runway-auth-health-phase1.md`) and fills in its
design-only Phase 2.

---

## 1. Goal & non-goals

Give Agent Sessions its own Claude OAuth session so runway meters (a) survive routine
access-token expiry (~30h) via a **silent** refresh-token grant — no browser, no banner,
no CLI — and (b) work for **Desktop-only users with no CLI installed**. Re-authentication
is asked for **only** when the refresh token itself is dead (weeks idle, revoked, explicit
logout), and then **only via a user-initiated banner action** — never an auto-launched
browser (the Safari-popup bug class we just mitigated in the cold-start path).
**Non-goals:** no surprise browser popups from any background path; never perform a
refresh-token grant against the CLI's shared `Claude Code-credentials` item (refresh
tokens rotate on use — refreshing the CLI's token would invalidate it and break the CLI);
no changes to usage-meter math, cadence, or the Codex side.

## 2. AS-owned OAuth session

AS performs its own one-time login and owns the resulting tokens end to end.

- **Flow:** PKCE authorization-code + loopback redirect (`http://localhost:<port>/callback`),
  the same shape the Claude Code CLI uses. Opens the system browser **only** from the
  banner's "Sign in to Claude" button (user click), runs a tiny local HTTP listener for the
  one callback, exchanges the code for tokens, closes.
- **Storage:** a **new, AS-owned Keychain item** — service `AgentSessions-claude-oauth`
  (name final at implementation) — written via the Security framework (`SecItemAdd`/
  `SecItemUpdate`), *not* the `security` CLI (that pattern in `ClaudeOAuthTokenResolver`
  exists only because the CLI's item belongs to another app). Payload mirrors the CLI's
  `claudeAiOauth` JSON: `accessToken`, `refreshToken`, `expiresAt` (ms),
  `refreshTokenExpiresAt` (ms), `scopes`.
- **New types:** `ClaudeOAuthLoginFlow` (PKCE + loopback, UI-triggered only) and
  `ClaudeOwnedCredentialStore` (Keychain codec, atomic read/write). Both live under
  `AgentSessions/ClaudeStatus/ClaudeOAuth/`.
- **TO CONFIRM before build (do not guess):** authorize URL; token endpoint URL;
  `client_id` (whether the CLI's public client id may be reused by a third-party app, or AS
  needs its own registration — this is also a ToS question); scope set (minimal: whatever
  gates `GET /api/oauth/usage`); loopback port strategy (fixed vs ephemeral; what redirect
  URIs the client registration allows); whether a revocation endpoint exists for sign-out.
  Confirm by reading the CLI's login traffic/source once, not by trial-and-error against
  the live auth server (see §7 ban risk).

## 3. Silent access-token refresh

New actor `ClaudeOAuthTokenRefresher`, used **exclusively for the AS-owned item**.

- **Grant (shape TO CONFIRM):** POST to the token endpoint with
  `grant_type=refresh_token`, `refresh_token`, `client_id`; response carries a new
  `access_token`, `expires_in`, and (rotation) a new `refresh_token`.
- **When it fires:**
  - *Pre-emptive:* `ClaudeOAuthTokenResolver.resolve()` gains expiry awareness for the
    AS-owned source — if `now >= expiresAt - skew` (skew ≈ 5 min), refresh before
    returning the token. (Requires `ResolvedToken` to carry `expiresAt` + a new
    `.asOwned` case in `TokenSource`, ordered first — see §6.)
  - *Reactive:* in `ClaudeUsageSourceManager.performOAuthFetch`'s
    `catch ClaudeOAuthUsageClientError.unauthorized` branch: if the resolved source was
    `.asOwned`, attempt the self-refresh and retry the fetch **once**; only on refresh
    failure fall through to `handleOAuthFailure`. For CLI-sourced tokens the existing
    `ClaudeDelegatedTokenRefresh` path is unchanged.
- **Rotation handling:** persist the rotated `refreshToken` + new `accessToken`
  **atomically to the AS Keychain item before first use** of the new access token; the
  refresher is an actor and single-flights concurrent callers (the source manager already
  has reentrant fetch paths — refreshNow, credential watcher, scheduled loop). If the
  response omits a rotated refresh token, keep the current one (TO CONFIRM whether
  rotation is always-on).
- **Outcome:** with an AS-owned session, a 401 self-heals with zero CLI spawns and zero
  browser. `classifyAndPublishAuthState(was401:)` is only reached when the refresh grant
  itself failed, so `.expired` now genuinely means "re-auth needed" rather than "routine
  30h expiry". No `UsageAuthState` is published during a successful silent refresh —
  the user sees nothing.

## 4. Re-auth UX (banner-driven, user-initiated)

Reuses the shipped machinery: `UsageAuthState` / `UsageAuthStatus`
(`AgentSessions/Shared/UsageAuthStatus.swift`), `AuthRemediationBanner`
(`AgentSessions/Shared/Views/AuthRemediationBanner.swift`), and the one-shot
`AuthStatusNotifier`. **No new states** — only the already-stubbed remediation case
`case inAppSignIn` is added to `Remediation`, rendered by the banner as a
"Sign in to Claude" button that launches `ClaudeOAuthLoginFlow`.

- **Banner appears only when re-auth is genuinely required:**
  - refresh-token grant fails with a definitive `invalid_grant` (dead/revoked), or
  - no token exists in any source (debounced `.signedOut` per Phase 1), or
  - `.cliNotInstalled` **and** no AS-owned session (today's Desktop-only hole).
- **Banner stays silent for:** routine access-token expiry with a live refresh token
  (silent refresh handles it); transient network/keychain failures (`.unknown`, per
  Phase 1's never-false-alarm rule); a refresh that failed for a *transient* reason
  (network) — retry on the existing failure cadence, don't alarm.
- **Remediation choice by audience** (in `UsageAuthStatus.make` or a small selector fed
  by `CLIBinaryPresence`): CLI installed → keep the existing monospace copy-command chip
  (`claude auth login`) **plus** the in-app button as an alternative; no CLI → in-app
  button only, and `.cliNotInstalled` copy drops its "(coming soon)" line.
- Notification behavior is unchanged: `AuthStatusNotifier` fires once per episode on
  `.signedOut`/`.expired`/`.cliNotInstalled`; a successful in-app sign-in publishes `.ok`
  which resets the episode. Menu-bar mirror unchanged. Banner layout/spacing per
  `agents.md` HIG rules — the button is a standard borderless button in the existing
  remediation slot, no new visual language.

## 5. Relationship to the CLI path

Once self-refresh lands, the interactive tmux `/usage` scraper
(`ClaudeTmuxUsageFallbackAdapter`) stops being an automatic fallback: in `auto` mode it
is skipped whenever an AS-owned session exists, and it survives only behind the explicit
`tmuxOnly` preference (opt-in), slated for removal in P2b. The lightweight
non-interactive `claude auth status` probe (`CLIAuthStatusProbe`, throttled 15 min on the
success path) is **retained** — it powers the "CLI signed out" advisory for CLI users.
`ClaudeDelegatedTokenRefresh` remains only for CLI-sourced tokens.

## 6. Migration / precedence

Token source precedence in `ClaudeOAuthTokenResolver.resolveUncached()` becomes:
**1. AS-owned Keychain item → 2. `CLAUDE_CODE_OAUTH_TOKEN` env → 3. CLI Keychain
(`Claude Code-credentials`) → 4. `~/.claude/.credentials.json`.**
Existing CLI users transition with **no forced re-login**: nothing changes until they
choose "Sign in to Claude"; until then AS keeps borrowing the CLI's access token
read-only (never refreshing it) exactly as today. After an in-app sign-in the AS item
simply wins the precedence race. Sign-out: a Preferences action deletes the AS item
(and revokes, if a revocation endpoint exists — TO CONFIRM), after which resolution
falls back to the CLI sources.

## 7. Risks & open questions

- **Rotation race:** the hard invariant is *AS never sends a refresh grant with a token
  read from the CLI's item* — enforced by routing all refreshes through
  `ClaudeOwnedCredentialStore`, which only holds AS-obtained tokens. Residual: CLI and AS
  each rotate their own chains independently; no shared state.
- **Keychain ACL:** SecItem-created items default to creator-app-only access — desired.
  TO CONFIRM accessibility class (`kSecAttrAccessibleAfterFirstUnlock` vs `WhenUnlocked`)
  so background refresh works after reboot-without-login-session edge cases.
- **Unconfirmed OAuth surface:** every endpoint/client_id/scope value in §2–§3 is
  TO CONFIRM; the client_id reuse question doubles as a ToS/policy check.
- **Ban risk / dev hygiene (owner-flagged):** the owner has been warned about excessive
  Claude web-auth requests. Development and tests MUST NOT hammer the live auth server:
  unit-test the refresher against a local mock token server; the full live flow is
  exercised **once** in owner QA (one login, one forced refresh), not in CI or loops;
  keep the delegated-refresh once-per-failure-cycle guard pattern for the new refresher.
- **Shared usage cache fingerprint:** `ClaudeOAuthUsageClient`'s `/tmp/claude` cache is
  keyed by token fingerprint; an AS-owned token won't match the CLI/statusline-warmed
  cache, so AS fetches fresh (~1/min, cadence unchanged). Acceptable; note only.
- **Stale hint cleanup:** `publishCLIAuthRequired()` in `ClaudeUsageSourceManager` still
  embeds the outdated `claude /login` hint — fold its removal into P1.5.

## 8. Phasing

- **P1.5 — Silent-refresh scaffolding:** `ClaudeOwnedCredentialStore` +
  `ClaudeOAuthTokenRefresher` + resolver `.asOwned` source with expiry awareness + the
  401 self-heal branch. Inert until an AS-owned item exists (seedable manually for QA).
  No UI change.
- **P2a — In-app sign-in:** `ClaudeOAuthLoginFlow` (PKCE + loopback), `Remediation.inAppSignIn`
  + banner button, Preferences sign-in/sign-out row, migration precedence live.
- **P2b — Retire the scraper:** tmux `/usage` becomes opt-in-only (then removed);
  delegated refresh removed for accounts with an AS-owned session.

Each phase is independently shippable; tests follow the Phase-1 pattern (pure,
table-driven; no live auth calls). New Swift files registered via
`scripts/xcode_add_file.rb`; commits per `agents.md` protocol.
