# Claude Cloud Session Source — Design

**Date:** 2026-07-31
**Status:** **VIABLE — Task 0 returned GO on 2026-07-31**, after an initial false NO-GO against the wrong API base. Recommended build is the Runway/QM per-session row slice. See §3.
**Problem:** Agent Sessions cannot see Claude Desktop sessions that run in the cloud against a remote repo.

> ## Verdict (2026-07-31)
>
> **Build the Runway/QM per-session row slice. Do not build transcript browsing.**
>
> Browsing was the weak idea and stays cut: Claude Desktop's own sidebar already shows cloud
> transcripts well, so a view-only reader duplicates a working UI. The version that would add
> unique value — cloud sessions in the FTS index so one search covers everything — remains
> excluded (§2) and should be decided on its own merits, not reached by accident.
>
> **Live per-session rows are a different and much stronger case.** Runway shows rows only while
> sessions are active, aggregated across agents; a cloud session running invisibly is a real gap
> that the desktop sidebar does not close, because closing it there means switching apps. The
> list endpoint (§3) returns exactly the fields this needs, so the slice is small.
>
> **Two corrections recorded here so they are not repeated:**
>
> 1. **An initial NO-GO was wrong.** It tested `/api/organizations/{org}/chat_conversations_v2`,
>    which is the claude.ai *chat* surface and legitimately contains no code sessions. The Code
>    tab uses an entirely different base, `/v1/code/sessions` (§3). Probing one namespace and
>    concluding "unreachable" was the error.
> 2. **"Cloud usage is missing from the quota figure" is a non-problem**, and was a
>    misreading of the question. Quota is account-level —
>    `~/Library/Application Support/Claude/plan-usage-history.json` samples only org-scoped `fh`
>    and `sd`, with no session dimension — so cloud work is already counted. Per-session token
>    *usage* remains unavailable; per-session *liveness* is what the list provides, and is what
>    Runway rows actually need.

---

## 1. Problem

A Claude Desktop session started against a **remote GitHub repo** (sidebar group "PingCraft",
target `remote:jazzyalex/PingCraft`) is invisible to Agent Sessions — absent from both the
main window and Quick Monitor, while actively chatting.

This is not an indexer bug. Verified on-machine 2026-07-31:

| Probe | Result |
|---|---|
| `~/.claude/**` grep for `PingCraft` / `remote:jazzyalex` | nothing (only this session's own transcript) |
| Desktop registry `claude-code-sessions/**` | 149 records, **all** `sessionId` `local_*`/`deleted_*`; **zero** with a `remote:` cwd |
| Whole Claude container, incl. `strings` over IndexedDB + Local Storage LevelDB | one hit: a permission-mode entry in `claude_desktop_config.json` |

Claude Desktop persists **no local record at all** for a cloud session — no title, no cwd, no
`cliSessionId`, no transcript. AS discovery
([`SessionDiscovery.candidateRoots()`](../../../AgentSessions/Services/SessionDiscovery.swift))
scans only `~/.claude/projects/**` and
`local-agent-mode-sessions/**/local_*/.claude/projects/**`. Neither can ever yield this session.

Making cloud sessions visible therefore requires a **network source**. That is what this
document specifies.

---

## 2. Scope

**In scope — live per-session rows only.**

- Poll `/v1/code/sessions`, keep `environment_kind == "anthropic_cloud"`, and render those as
  **Runway rows while they are active**, alongside local agent rows.
- Liveness comes from fields already in the list payload — no per-session probing.

**Explicitly out of scope.**

| Excluded | Why |
|---|---|
| Transcript fetching and a browsing UI | Cut after the endpoint was verified. Claude Desktop's sidebar already renders cloud transcripts well; a read-only reader duplicates a working UI for no gain. Runway rows are the part the sidebar does not cover, because reading it means switching apps. |
| `environment_kind == "bridge"` rows (168 of 177) | Bridged to a local device, so AS's local indexer very likely already shows them. Rendering both would duplicate rows. |
| Writing cloud sessions to `index.db` | Keeps this additive: no schema change, no hydration path, no migration. Avoids the known NULL-surface-metadata trap where DB-hydrated rows lose provenance and features gated on it silently break. |
| Offline / cross-source search | Follows from the above. Cloud sessions are not in the FTS index, so they do not appear in local search results. |
| Resume | There is no local checkout and no local process to attach to. Independently, desktop apps cannot be switched to a specific session from outside — built and rolled back 2026-07-21. |
| Archive / restore / delete | Read-only source. No mutating calls. |
| Persisting transcript content to disk | Privacy: server-side conversation content stays in memory only. See §7. |

---

## 3. Endpoint contract — VERIFIED 2026-07-31

**The Code tab does not use the `/api/organizations/...` surface at all.** It uses a separate
API base, found in `app.asar` (`/v1/code/sessions`, alongside an id validator
`/^(?:session|cse)_[A-Za-z0-9._:-]+$/`) and then confirmed live.

```
GET https://claude.ai/v1/code/sessions?limit=100[&cursor=<next_cursor>]

  headers:
    Cookie: sessionKey=<key>
    anthropic-version: 2023-06-01
    anthropic-beta: ccr-byoc-2025-07-29
    anthropic-client-feature: ccr
    x-organization-uuid: <org uuid>

  → 200 {"data": [...], "next_cursor": <str|null>, "resume_token": <str>}
```

Measured: **177 sessions** enumerated across cursor pages, every id `cse_`-prefixed.

Row fields:

```
id  title  status  status_bucket  worker_status  connection_status
last_event_at  created_at  environment_id  environment_kind
unread  user_message_count  participants  relations  tags  config
external_metadata
```

Observed value vocabulary across all 177 rows:

| Field | Values (count) |
|---|---|
| `status` | `archived` 166, `active` 11 |
| `status_bucket` | `completed` 165, `working` 6, `review_ready` 5, `failed` 1 |
| `worker_status` | `idle` 166, `running` 5, `WORKER_STATUS_UNSPECIFIED` 6 |
| `connection_status` | `connected` 165, `disconnected` 12 |
| `environment_kind` | `bridge` 168, `anthropic_cloud` 6, absent 3 |

Live confirmation — the session that started this investigation, read while it was working:

```
title              PingCraft game design prototype
id                 cse_01CrqxLv…
status             active         status_bucket     working
worker_status      running        connection_status connected
last_event_at      2026-08-01T02:19:02Z
unread             1              environment_kind  anthropic_cloud
```

### 3.1 `environment_kind` is the filter that matters — not the `cse_` prefix

All 177 rows are `cse_`-prefixed, so the prefix does **not** discriminate. `environment_kind`
does:

- `anthropic_cloud` (6) — true cloud sandbox. **This is the feature's target.**
- `bridge` (168) — sessions bridged to a local device, which AS very likely already sees
  through its local indexer. Including these would double-render rows that are already on
  screen. **Filter them out**, or reconcile against local sessions before rendering.

An earlier draft proposed filtering on `id.hasPrefix("cse_")`. That would surface all 177 and
duplicate the local ones. Filter on `environment_kind == "anthropic_cloud"` instead, and treat
an absent `environment_kind` as "not cloud" rather than guessing.

### 3.1b Transport note — curl is not a valid probe for this API

`curl` receives `403 text/html` (Cloudflare interstitial) on every claude.ai API path, even with
a valid `sessionKey`. The same requests through `URLSession` (ephemeral config, identical

### 3.1b Transport note — curl is not a valid probe for this API

`curl` receives `403 text/html` (Cloudflare interstitial) on every claude.ai API path, even with
a valid `sessionKey`. The same requests through `URLSession` (ephemeral config, identical
headers) return `200 application/json`. The difference is TLS fingerprinting, not auth.

Two consequences: AS's existing `ClaudeWebUsageClient` is **not** affected — it uses URLSession
and clears fine. And any future probe of this API must be written against URLSession; a shell
script using curl will report false negatives. **Do not conclude "blocked" from a curl 403.**

### 3.2 Do not call

`/api/organizations/{org}/cowork/messages/{msgId}/safety_flags` is per-message and appears
hundreds of times in the cache. Calling it would mean N requests per transcript against an
undocumented endpoint. Never call it.

### 3.3 Task 0 result — GO (measured 2026-07-31)

`/v1/code/sessions` enumerates cloud sessions with full liveness fields (§3). Risk 10.1 did
**not** fire. The list-poll presence model in §5 is supported.

**Dead end recorded so it is not retried.** The first Task 0 run tested
`/api/organizations/{org}/chat_conversations_v2` and returned NO-GO. That result was correct
about that endpoint and wrong about the feature:

- 220 rows, paged to exhaustion, all `platform: CLAUDE_AI`, all bare-UUID ids, `session_id` null
  throughout. It is the claude.ai **chat** list and contains no code sessions by design.
- `platform` is not a filterable parameter — `CLAUDE_CODE`, `COWORK`, and a deliberately invalid
  value all return 200 with identical rows.
- `chat_conversations/{cse_id}` rejects `cse_` ids: `path.chat_conversation_uuid: Input should
  be a valid UUID … found 's' at 2`. Correct, because `cse_` ids belong to `/v1/code/sessions`,
  not to the chat namespace.

**The methodological lesson**, which is the durable part: probing one namespace and concluding
"unreachable" is invalid when a working client visibly does the thing. The desktop sidebar
rendered the session throughout. That visible contradiction should have triggered "wrong
namespace" immediately instead of a NO-GO writeup. The endpoint was then found by grepping
`app.asar` for `/sessions` path segments — a search that had been run earlier but filtered too
narrowly (`/api/...` only), which is what hid `/v1/code/sessions`.

---

## 4. Auth reuse

**No new auth mechanism.** Reuse the existing manually-pasted claude.ai `sessionKey`
(`ClaudeManualWebCookie`, `ClaudeWebCookieResolver`), which already backs the web usage source.
Request shape mirrors `ClaudeWebUsageClient` exactly: `Cookie: sessionKey=…`, `Accept:
application/json`, ephemeral `URLSession`, 8s request / 12s resource timeouts, org UUID resolved
once and cached in memory.

Rationale: the decision to use a pasted cookie rather than embedded login or scraping was
already settled; Safari on macOS 14/15 no longer exposes the live `sessionKey` to apps, so
automatic extraction is not available. Adding a second auth path would double the surface for
no gain.

**One consequence must be designed for, not inherited.** Today the cookie is *optional* — absent
cookie simply means no web usage numbers. Under this feature, absent cookie means an entire
source is empty. That must never render as an empty list with no explanation. The cloud source
therefore owns an explicit, always-rendered state (§6) and a "Connect claude.ai" affordance
pointing at the same Settings field the usage source uses.

---

## 5. Presence model

Runway/QM gets cloud rows from **the list poll only**. One request per tick, no per-session
probing — the list payload already carries everything.

**Active-row predicate** (Runway shows rows only while sessions are active):

```
environment_kind == "anthropic_cloud"
  AND status == "active"
  AND status_bucket ∈ { "working", "review_ready" }
```

**Row state mapping:**

| Signal | Source field | Notes |
|---|---|---|
| working now | `worker_status == "running"` | the strongest liveness signal |
| waiting on you | `status_bucket == "review_ready"` | distinct from working — surface it differently |
| last activity | `last_event_at` | ISO-8601 UTC |
| attention badge | `unread` | integer |
| lost the sandbox | `connection_status == "disconnected"` | render as degraded, not as gone |

`worker_status` also takes `WORKER_STATUS_UNSPECIFIED` (6 of 177 observed). Treat it as unknown
and fall back to `status_bucket`; never render it as a literal.

Cadence rides QM's existing timer rather than adding a second one. Backoff, `Retry-After`
handling, and stale-data semantics reuse the machinery built after the usage 429 incident
(edge 429s on `oauth/usage` carried `Retry-After` up to ~47 minutes).

The N+1 alternative — probing each session per tick — was considered and rejected: it multiplies
requests against an undocumented endpoint with a demonstrated rate-limit history, to sharpen a
signal the list payload likely already carries.

---

## 6. Failure modes

The governing lesson from the QM reconnecting-forever bug: **a failure state that is computed
but not rendered becomes an infinite spinner.** Every state below has a distinct, visible
rendering. There is no state whose UI is "keep spinning".

| State | Trigger | Rendering | Recovery |
|---|---|---|---|
| `notConnected` | no `sessionKey` stored | "Connect claude.ai to see cloud sessions" + link to Settings | user pastes cookie |
| `expired` | 401 | "claude.ai session expired — paste a fresh cookie" | user repastes |
| `rateLimited(until:)` | 429 | "Rate limited — retrying at HH:MM", last-known rows kept, marked stale | auto, honors `Retry-After` |
| `offline` | transport error | "Offline — showing last known", rows marked stale | auto on next tick |
| `contractDrift` | 2xx but decode fails | "Cloud sessions unavailable (API changed)" + Console detail | needs a release |
| `empty` | 2xx, zero `cse_` rows | "No cloud sessions" — distinct from every row above | n/a |
| `ok` | rows present | normal | n/a |

Notes:

- **`empty` vs `notConnected` must never collapse into one look.** That conflation is exactly
  what made the original bug feel like "AS is broken" rather than "AS is not connected".
- **Contract drift is expected, not exceptional.** These are undocumented endpoints that can
  change without notice. Decoding is lenient — unknown fields ignored, a row that fails to
  decode is skipped rather than failing the batch — but a *total* decode failure surfaces as
  `contractDrift` instead of silently rendering `empty`.
- Stale data is always labelled. Showing last-known rows is correct; showing them as if fresh
  is not.
- The cloud source is **fully isolated**: any failure in it leaves local sessions untouched. It
  cannot block, slow, or empty the local list.

---

## 7. Privacy and trust

- Transcripts live in an in-memory LRU only, dropped on quit. Nothing written to `index.db`,
  no cache file on disk.
- The source is **opt-in** and off by default. It makes network requests carrying the user's
  session cookie; that is not something to enable silently.
- Only `GET` requests. No mutating calls anywhere in this design.
- The feature ships labelled **experimental**, because it depends on undocumented endpoints
  that may break at any release.

---

## 8. Module boundaries

New folder `AgentSessions/ClaudeCloud/`, mirroring the `ClaudeStatus/ClaudeOAuth` layout.

| Unit | Responsibility | Depends on |
|---|---|---|
| `ClaudeCloudAPIClient` | actor; the four `GET`s, cookie header, org-id cache, HTTP→error mapping | existing cookie resolver |
| `ClaudeCloudSessionCatalog` | list, filter to `cse_`, TTL cache, owns `ClaudeCloudSourceState` | API client |
| `ClaudeCloudTranscriptStore` | on-demand transcript fetch, in-memory LRU | API client |
| `ClaudeCloudTranscriptMapper` | API message tree → existing view model | model types only |
| `ClaudeCloudPresenceAdapter` | catalog rows → QM rows | catalog |

Each is independently testable against recorded JSON fixtures; nothing here needs a live network
in tests. The mapper is deliberately separate from the fetcher so contract drift is diagnosed in
one place.

---

## 9. Testing

- Fixture-driven decode tests per endpoint, including a deliberately drifted fixture that must
  produce `contractDrift` and not `empty`.
- State-machine tests covering every row in §6, asserting each yields a distinct rendered
  string — the regression guard against silent-spinner recurrence.
- A test asserting no cloud code path touches `index.db`.
- Filter test: `local_*` and bare-UUID conversations are excluded from the cloud source.

---

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `chat_conversations_v2` does not list `cse_` rows | **fatal to this design** | Phase 0 go/no-go before any implementation |
| Endpoints change without notice | high | lenient decode, `contractDrift` state, experimental label |
| Rate limiting | medium | single list request per tick, reuse existing backoff |
| Cookie expiry is invisible to the user | medium | explicit `expired` state with a repaste affordance |
| Scope creep into indexing/search | medium | §2 exclusions are part of the contract, not preferences |

---

## 11. Prior art check

Not done. Before implementing, check whether CodexBar or AgentsView already read cloud sessions
— if either has solved the list-enumeration question, that answer is worth more than a probe.
