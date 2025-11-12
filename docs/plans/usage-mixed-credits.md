# Plan: Mixed Subscription + Usage-Based Credits

Status: Draft (do not implement yet)

Goal: Support users whose providers offer both subscription-based caps (e.g., 5h / weekly windows) and on-demand credit balances. Display whichever constraint matters most, clearly and consistently, while avoiding surprise polling or token spend.

## Data Model

- Add `UsagePlanType` per source: `.subscriptionCaps`, `.usageCredits`, `.mixed`.
- Extend snapshots with optional credit fields: `creditBalanceUSD`, `creditUpdatedAt`, `creditRefreshAt`, `creditTTL`, `creditUnitPrice`.
- Computed `activeLimiter` selects which limiter to surface (caps first if enforced; credits otherwise). Make precedence a policy flag for future change.

## Probes (Manual Only)

- Add billing probe adapters (`codex_billing_capture.sh`, `claude_billing_capture.sh`) that fetch current balance. Never auto-run; only via explicit user action.
- TTL: default 6h (`FreshUntilCredits*`). Persist to survive relaunch.
- Manual probes only; do not add automatic schedulers or hidden background polling.

## UI

- Strips: show a right-aligned “Credits: $12.30” badge when plan type is not `.subscriptionCaps` and data is fresh; tooltip includes last updated time and a link to Preferences.
- Menu Dropdown: add a per-source “Credits: $X.XX” line; show “Stale. Refresh in Preferences” when beyond TTL.
- Preferences > Usage Tracking: add a “Billing” section with “Refresh Billing” and “Balance last updated: …”. Include copy that this action may contact the provider.
- Option: “Prefer credits when available” to display credits first in strips/menu.

## Behavior

- After a successful billing refresh, set `FreshUntilCredits* = now + 6h`.
- When both caps and credits exist, caps remain the primary limiter unless policy flips (configurable).

## Testing

- Unit tests: `activeLimiter` selection, TTL, and formatters for caps vs credits.
- Fixtures for CLI/JSON outputs with typical edge cases (low balance, currency variants, missing fields).

## Rollout

1) Implement data model + Preferences section behind a feature flag; no strip/menu changes.
2) Add optional strip/menu lines for credits (opt-in).
3) Default-on once validated, refine copy and thresholds.
