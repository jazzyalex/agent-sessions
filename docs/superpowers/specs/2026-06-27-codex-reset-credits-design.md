# Codex Reset Credits in Quota Meter & Menu Bar

**Date:** 2026-06-27
**Status:** Approved (design)
**Source request:** [openai/codex#28963 — "Show Codex reset credits directly in the macOS app"](https://github.com/openai/codex/issues/28963)

## Problem

OpenAI grants ChatGPT/Codex accounts free **reset credits** — one-shot "reset your
usage now" grants that are separate from the rolling-window reset *times* the app
already shows (5h resets at X, weekly resets at Y). Each credit has a grant date and
an expiry date, and there is an available count. These credits are valuable but easy
to miss: users may not know they have any, when they expire, or whether one was
already redeemed.

Agent Sessions already mirrors Codex usage in the Quota Meter (QM) and the menu bar,
so it is a natural place to surface reset credits too.

## Scope

- **Display only.** Read-only fetch and render. No redeem/"reset now" action.
- **Codex only.** The endpoint is ChatGPT/Codex-specific; Claude has no equivalent.
  Credits render only under the Codex provider block on every surface.
- **Two surfaces:** the QM hover-expanded panel, and the menu-bar dropdown items.

Explicitly out of scope (YAGNI): redeem action, Claude support, a dedicated
preference toggle, persistent on-disk caching across launches.

## Constraints

- **Privacy (issue acceptance criteria):** never store, log, render, or copy auth
  tokens, account IDs, or credit IDs. Only grant/expiry dates, the available count,
  and status reach the UI layer.
- **No resting-row reflow.** The compact QM row must not change width or content;
  credits appear only in the hover-expanded panel.
- **Slow-moving data.** Credits are granted ~monthly and expire ~monthly; the fetch
  must not add polling pressure.

## Architecture

### 1. Data model — one source feeds both surfaces

The menu bar's `codexStatus` and the cockpit both observe the single shared
`CodexUsageModel` (`AgentSessions/CodexStatus/CodexStatusService.swift:140`). Credits
live there:

```swift
struct CodexResetCredit: Equatable {
    let grantedAt: Date?
    let expiresAt: Date?
    let status: String?   // "available" | "redeeming" | "redeemed" | "expired" | nil
}

// on CodexUsageModel
@Published var resetCreditsAvailable: Int = 0
@Published var resetCredits: [CodexResetCredit] = []
@Published var resetCreditsLastFetch: Date? = nil
```

Only render-relevant fields are stored — no tokens, account IDs, or credit IDs.

### 2. Fetch path — sibling of the existing usage fetcher

New `CodexResetCreditsFetcher`, modeled on
`AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift`. Reuses:

- `CodexOAuthCredentials.resolve()` for the `Bearer` token + `ChatGPT-Account-Id`.
- An ephemeral `URLSession` with the same short timeouts.
- The same 401 (invalidate cache) / 429 (back off with `Retry-After`) handling.

Differences:

- **Endpoint:** `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
- **Headers:** the bare request mirrors the existing usage call (which works without
  extra headers). The issue's reference script additionally sends
  `OpenAI-Beta: codex-1` and `originator: Codex Desktop`. Send these **only if** the
  bare request returns 403/404 — confirmed empirically during implementation, not
  assumed.
- **Decoding:** defensive optional decode of
  `{ "available_count": Int?, "credits": [{ "granted_at": String?, "expires_at": String?, "status": String? }]? }`.
  Dates parse via ISO 8601. Fails closed: a nil/garbage response leaves the model
  untouched (last good values persist).

**Cadence:** piggyback on the existing usage poll but gate with its own long
cooldown (≈6h on success, ≈30m on failure). Also refresh on the manual hard-probe
that QM's double-click already triggers. No new timer is introduced.

### 3. QM surface — extra line, hover only

The hover-expanded panel is `HUDLimitsDetailPanel`
(`AgentSessions/Views/AgentCockpitHUDView.swift:4197`), shown via
`shouldShowExpandedPanel`. The compact resting row is untouched.

Inside that panel, **under the Codex provider block only**, when there is at least
one non-expired/non-redeemed credit, render one secondary line:

- One credit: `↑ 1 reset credit · expires Jul 17`
- Multiple: `↑ 3 reset credits · next expires Jul 17` (earliest expiry)

Expiry-only (no grant date) per approved design. Styling reuses the panel's existing
`.secondary` treatment and `AppDateFormatting` date formatting. No new layout
columns, so resting QM width never reflows. If no renderable credits remain, the
line is omitted.

### 4. Menu-bar surface — items under the Codex subsection

In `UsageMenuBar` (`AgentSessions/MenuBar/UsageMenuBar.swift:291`), inside the Codex
`VStack`, after the `Wk:` line and before the "Updated" timestamp, add a section that
renders when credits exist. This appears under the Codex subsection in **both** the
Codex-only and the `.both` (Codex + Claude) menu layouts:

```
Reset credits
1 available · expires Jul 17, 2026
```

With multiple credits, list each `expires …` on its own line (the menu has vertical
room, unlike QM). Like the existing reset lines, the section opens Usage preferences
on tap. The menu-bar **title/strip** is not changed.

### 5. Shared formatter

A pure function — `resetCreditSummaryLine(available:credits:now:)` — produces the
count + earliest-expiry string and filters out `expired`/`redeemed` statuses. Both
surfaces call it so the wording and filtering logic exist in exactly one tested
place. (Menu bar additionally enumerates per-credit expiry lines from the same
filtered list.)

### 6. Empty / unavailable states

- Zero renderable credits, or fetch never succeeded → render nothing on both
  surfaces (no "No resets available" placeholder), matching how the app hides absent
  data elsewhere.
- Codex usage disabled or logged out → no fetch, no UI.

## Testing

- **Decoder:** unit-test against the issue's sample payload plus edge cases — zero
  credits, missing `granted_at`/`expires_at`, unknown/absent `status`, multiple
  credits, malformed JSON (fails closed).
- **Formatter:** unit-test `resetCreditSummaryLine` for 0 / 1 / N credits and for
  status filtering (expired/redeemed excluded; count reflects only renderable ones).
- **No network in tests:** the fetcher's decode/normalize step takes injected data,
  mirroring the existing usage-fetcher tests.

## Files touched (anticipated)

- `AgentSessions/CodexStatus/CodexOAuth/CodexResetCreditsFetcher.swift` (new)
- `AgentSessions/CodexStatus/CodexStatusService.swift` (model fields + wiring)
- `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDLimitsDetailPanel` line)
- `AgentSessions/MenuBar/UsageMenuBar.swift` (Codex subsection section)
- A shared formatter as a small standalone helper file,
  `AgentSessions/Utilities/CodexResetCredits.swift`, holding the `CodexResetCredit`
  type and the `resetCreditSummaryLine(...)` function so both surfaces and tests
  import one place.
- New test file(s) under `AgentSessionsTests/`.

New Swift files are registered via `scripts/xcode_add_file.rb` per `agents.md`.

## Acceptance criteria (from the issue, scoped to display-only)

- App shows the number of available Codex reset credits when present.
- App shows each credit's expiry date (grant date intentionally omitted in QM per
  approved design; menu bar shows expiry).
- No auth tokens, account IDs, or credit IDs appear in UI, logs, diagnostics,
  screenshots, or copied text.
- UI handles zero, one, and multiple credits.
- UI handles redeemed / redeeming / expired / available statuses (non-renderable
  ones filtered out).
- Date/time rendering uses the user's local timezone.
