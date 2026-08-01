# Local Usage History — Design

**Date:** 2026-07-31
**Status:** Design — awaiting review
**Goal:** Give Runway a usage *history* and an auth-free fallback, by reading a file Claude Desktop already maintains.

---

## 1. Why

Two gaps, one file closes both.

**AS has no usage history.** `ClaudeUsageSnapshotStore` writes a single file,
`claude_usage_latest.json` — the latest snapshot only. Every earlier reading is discarded, so
Runway can answer "how much is left?" but not "how does my week normally go?" or "when do I
usually hit the wall?".

**Every current usage path can fail, and they fail together.** Live readings come from
`api.anthropic.com/api/oauth/usage` or `claude.ai/api/organizations/{org}/usage`. Those are
subject to edge 429s carrying `Retry-After` up to ~47 minutes, expired-cookie 401s, and
Full-Disk-Access blocks. That cluster is exactly what produced the reconnecting-forever bug,
where a degraded state with no rendered surface looked like an infinite spinner.

Claude Desktop already keeps a local time series that fixes both:

```
~/Library/Application Support/Claude/plan-usage-history.json
```

Measured on-machine 2026-07-31:

| Property | Value |
|---|---|
| Shape | `{"version": 2, "samples": [{"t": <epoch ms>, "org": "<uuid>", "u": {"fh": <int>, "sd": <int>}}]}` |
| Samples | 3,653 |
| Span | 2026-07-07 16:29 → 2026-07-31 15:04 (23.9 days) |
| Median gap | 300 s (5-minute cadence) |
| Keys in `u` | `fh`, `sd` only — no other metrics, **no per-session attribution** |

No auth. No network. No rate limit. It cannot 429, cannot expire, and does not need Full Disk
Access. It is already on disk right now.

---

## 2. Scope

**In scope.**

- Read and parse `plan-usage-history.json`, filtered to the active org.
- Render a usage trend in Runway (sparkline / recent history).
- Serve as a **fallback** source when every live path is unavailable, clearly labelled as
  locally-recorded rather than live.

**Out of scope.**

| Excluded | Why |
|---|---|
| Writing to the file | It belongs to Claude Desktop. Read-only, always. |
| Mirroring samples into an AS-owned store | YAGNI for v1. The desktop already retains ~24 days; a 7-day view needs no mirror. Revisit only if §6 shows the file is trimmed below the window Runway displays. |
| Replacing the live usage path | This file lags by up to 5 minutes and only exists when Claude Desktop is installed. It supplements; it never replaces. |
| Per-session usage | Not in the data. `u` carries `fh`/`sd` only, org-scoped. Confirmed absent, not merely unimplemented. |
| Codex/other agents | Anthropic-specific file. |

---

## 3. Semantics — establish before use

`fh`/`sd` are *presumed* to be five-hour and seven-day utilization percentages, matching the
`five_hour` / `seven_day` keys the web API returns in `ClaudeWebRawUsageResponse`. The naming
lines up and the value ranges are plausible, but **presumed is not verified**, and shipping a
number whose unit or window is wrong is worse than shipping none.

Before any of this reaches the UI, confirm three things:

1. **Unit** — is `fh: 20` twenty percent, or twenty of some raw count? Compare a sample against
   a live reading taken at the same moment.
2. **Window** — does `fh` track the same rolling five-hour window Runway already classifies, or
   the fixed slot? This matters because OpenAI's window semantics already caused one
   misclassification; do not assume Anthropic's are stable either.
3. **Multi-org** — does the file interleave samples from several orgs, or only the active one?
   The `org` field exists, so filtering is mandatory regardless of the answer.

If any of the three cannot be established, ship the trend as a **relative** shape (unitless
sparkline) rather than labelled percentages. A shape that is honest beats a number that is
precise and wrong.

---

## 4. Design

One new reader, one small view addition. Nothing existing changes behaviour.

| Unit | Responsibility |
|---|---|
| `ClaudeLocalUsageHistoryReader` | Locate the file, decode, version-gate, filter by org, return `[UsageSample]`. Pure and synchronous; no network, no writes. |
| `UsageSample` | `struct { let at: Date; let fiveHour: Int; let sevenDay: Int }` |
| Runway view addition | Render the trend; render the fallback label when live data is absent. |

**Version gating.** The file declares `"version": 2`, which means the shape has already changed
at least once. The reader accepts version 2 and refuses anything else, returning an empty
history rather than guessing — a wrong sparkline is worse than no sparkline. An unexpected
version is logged once, not per read.

**Foreign-file discipline.** Another process writes this file on a 5-minute cadence, so a read
can land mid-write. Read once into memory and decode; on any decode failure return empty and
retry on the next cycle. Never partially apply a bad parse. Never hold a lock. Never write.

**Absence is normal.** Users without Claude Desktop have no such file. That is not an error
state and must not render as one — the trend simply does not appear.

---

## 5. Failure modes

Same discipline as the cloud spec: no state may exist that has no rendered surface.

| State | Trigger | Rendering |
|---|---|---|
| `unavailable` | file absent (no Claude Desktop) | trend section hidden entirely — not an error |
| `unsupportedVersion` | `version != 2` | trend hidden; one Console log |
| `unreadable` | decode failure / partial write | trend hidden this cycle; retried next cycle |
| `staleOnly` | file present, live sources all down | trend shown **plus** "Recorded locally, up to 5 min behind" |
| `ok` | file present, live source healthy | trend shown alongside the live figure |

`staleOnly` is the state that earns this feature. It is the case that currently renders as a
spinner, and here it renders as real numbers with an honest caveat.

---

## 6. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `fh`/`sd` semantics guessed wrong | **high** | §3 gate — verify unit/window/org before labelling anything a percentage; fall back to a unitless sparkline |
| Desktop trims history shorter than the displayed window | medium | Measure retention over a week before choosing the window. If trimmed below it, revisit the mirror decision excluded in §2 |
| File shape changes (`version` bumps) | medium | Version gate; empty history, never a guess |
| Feature reads as "AS needs Claude Desktop" | low | Absent file hides the section silently; no prompt, no nag |
| Scope creep into a general metrics store | medium | §2 exclusions are contractual |

---

## 7. Why this over the cloud-session source

Both were scoped on 2026-07-31. This one is smaller, helps more users, and cannot break:

|  | Cloud session source | Local usage history |
|---|---|---|
| Auth | expiring cookie | none |
| Network | undocumented endpoints | none |
| Can be rate-limited | yes (429, ~47 min) | no |
| Breaks when vendor changes API | yes | only on a local file version bump, which is detectable |
| Users helped | those running cloud sessions | everyone with Claude Desktop |
| Duplicates an existing UI | yes (desktop sidebar) | no — nothing shows this today |

These are independent and both live. The cloud-session work was cut down to **live Runway rows
only** (its Task 0 came back GO — cloud sessions do enumerate at `/v1/code/sessions`); transcript
browsing was dropped. See
[`2026-07-31-claude-cloud-session-source-design.md`](2026-07-31-claude-cloud-session-source-design.md).

This design stands on its own regardless: it needs no cookie, no network, and no undocumented
endpoint, and it helps every user with Claude Desktop installed rather than only those running
cloud sessions.
