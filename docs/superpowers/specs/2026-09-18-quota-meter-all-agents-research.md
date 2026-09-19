# Quota Meter: all-agent coverage research

**Date:** 2026-09-18
**Status:** research only; no implementation is included in this document
**Scope:** all seventeen declared `SessionSource` agents, including DeepSeek Harness, local session history, live presence, CLI/headless/headed/Desktop surfaces, live burn-rate, local API-equivalent pricing, weekly quota, runway, and steward work

**Integration update (2026-09-19):** DeepSeek Harness history support has landed on `main` for the planned 5.5 release, but has not been deployed. This research did not audit DSH live usage or quota telemetry; history parsing and UI smoke tests do not establish that contract.

## Executive conclusion

Quota Meter should not become one universal number for every agent. The evidence supports five separate capability layers:

1. **Session inventory:** source, session name, session ID, model, project/cwd, last activity, and whether the source is currently present.
2. **Surface identity:** CLI, headed terminal, headless CLI/server, Desktop, VS Code/IDE, subagent, or unknown.
3. **Live burn-rate:** tokens per hour is the minimum useful live metric. API-equivalent dollars per hour is the preferred richer metric when model, provider, and token component prices are known.
4. **Cost display:** native provider-reported cost, API-equivalent estimate, or free (catalog price 0). These are different claims and must not share one label.
5. **Account quota and runway:** a provider-authoritative account window plus a defensible attribution model. This is currently a Codex/Claude capability, not a property of token counts.

The product recommendation is therefore:

- Keep the compact **Quota Meter** provider rows for Codex and Claude, where account-level quota feeds already exist.
- Add a separate **Live sessions** area inside the expanded QM/detail surface. It may list any agent for which presence is proven, even when quota is unavailable.
- Do not stop at presence. A live row should show `tokens/hour` whenever observed timestamps and token deltas pass the source gates; show `$ / hour` only when a native cost or complete local API-equivalent price calculation is available.
- Make **OpenCode the next Quota Meter vertical slice**. Its local database already contains per-message usage, the current reader already loads those rows, and the live source only has the documented headless admission gap.
- Keep **DeepSeek Harness (DSH) on the history-source track**. The history source is merged for the planned 5.5 release; live following and quota/cost telemetry remain out of that release. After 5.5, audit the accepted usage fields against a real store before connecting them to a telemetry accumulator.
- Use only a **local price catalog** in the near-term. Provider account Usage/Costs, billing, credits, and balance adapters are deferred; they add credentials, network access, account scope, and ongoing provider maintenance.
- Show **pricing** only with provenance: `native reported`, `API-equivalent estimate`, `Free (promo route)`, `included/subscription`, or `unavailable`. For OpenCode, classify `Free (promo route)` from the local catalog’s zero prices, never from a suffix or a local `cost = 0`; never turn it into “$0 spent”.
- Do not make weekly or five-hour quota a requirement for the new all-agent live surface. Keep those windows only where the existing provider integration is authoritative enough. Do not infer quota from tokens, model price, session age, or a subscription name.
- Do not show a runway for an agent without an authoritative account window and a stable identity/attribution contract.

This is a capability map, not a claim that all rows should ship together. The benchmark and the repository both show that “the agent”, “the surface”, and “the artifact family” are different units.

## Evidence and limits

### Repository evidence

The current app declares seventeen sources in [`SessionSource.swift`](../../../AgentSessions/Model/SessionSource.swift#L3-L30). The source descriptor layer is the current product capability contract: it distinguishes supported, partial, and unavailable configuration, tokens, cost, and weekly quota in [`SessionSourceDescriptor.swift`](../../../AgentSessions/Model/SessionSourceDescriptor.swift#L200-L216).

The telemetry engine currently dispatches only Codex, Claude, Pi, and Copilot. A descriptor can say that another source is available, but it will not produce data until an accumulator/reader is added; the dispatch set is explicit in [`SessionTelemetryEngine.swift`](../../../AgentSessions/Telemetry/SessionTelemetryEngine.swift#L95-L102), and its source switch is in [`SessionTelemetryEngine.swift`](../../../AgentSessions/Telemetry/SessionTelemetryEngine.swift#L174-L207).

The active-session subsystem currently accepts only Codex, Claude, Antigravity, and OpenCode as live sources ([`CodexActiveSessionsModel.swift`](../../../AgentSessions/Services/CodexActiveSessionsModel.swift#L653-L666)). The active row already has the fields needed for a useful inventory — source, display name, TTY, terminal program, session IDs, log path, cwd, activity, idle reason, and subagent count — in [`AgentCockpitHUDView.swift`](../../../AgentSessions/Views/AgentCockpitHUDView.swift#L71-L96).

### Session-Bench evidence

[Session-Bench](https://github.com/jazzyalex/session-bench) is the canonical benchmark repository. Its current public board is v0.4, corrected 2026-08-23, and covers ten **CLI/headless session stores**, not every surface. It explicitly says that Desktop and IDE stores may differ and need their own rows ([repository README](https://github.com/jazzyalex/session-bench#scope-and-honesty-notes-v04)).

The benchmark’s most useful distinction for QM is its completeness area:

| Harness in the benchmark | Local token record | Local dollar record | QM implication |
|---|---:|---:|---|
| Pi | yes | yes | Good candidate for session tokens and native cost; no account quota. |
| OpenClaw | yes | yes | Good candidate after selecting the authoritative usage layer. |
| OpenCode | yes | yes | Strong candidate; current app reader does not yet extract the fields. |
| Hermes | yes | yes | Strong candidate; the SQLite row is already available to the reader. |
| Claude Code | yes | no | Tokens can be shown; dollars require a labelled estimate, not a native spend claim. |
| Codex | yes | no | Tokens can be shown; dollars are API-equivalent only. |
| Kimi Code | yes | no | Tokens only; the current parser ignores the measured records. |
| Copilot CLI | partial/summary | no native dollars | Completed-session summary only; no live per-turn meter. |
| Antigravity | no | no | Session/presence metadata only. |
| Cursor Agent | no | no | Session metadata only; Desktop history is also incomplete today. |

These are format observations, not provider-billing guarantees. Session-Bench measures local artifacts, not cloud account state, invoices, or quota windows. Its backlog’s proposed cross-surface contract is directly relevant: compare **harness**, **surface**, and **artifact family** separately; add a surface row only when roots, formats, companions, event vocabulary, or retention differ; and do not infer Desktop support from a marketing claim or shared binary ([cross-surface backlog](https://github.com/jazzyalex/session-bench/blob/main/BACKLOG.md#p0--define-cross-surface-local-persistence)).

### Fresh local telemetry findings

The repository’s measured follow-up is newer and more useful for implementation planning than a fixture-only scan:

- OpenCode’s `opencode.db` has session-level `model`, `cost`, input/output/reasoning/cache token columns and per-message `message.data` token/cost/model fields. The earlier repository snapshot recorded the model-field gap ([`docs/backlog.md`](../../backlog.md#L257-L264)); a later local sample confirmed that the reliable model field is in `message.data.modelID`, not the session model blob, and one session may switch models. The usage reader must therefore aggregate and price per message, then group the result by model/provider route. Exact local session and usage totals are omitted from this public research note.
- Hermes has a pre-aggregated SQLite row containing input/output/cache/reasoning tokens, estimated and actual cost, cost status, pricing version, billing provider, and billing mode. `cost_status = included` is subscription billing, not a zero-dollar API call ([`docs/backlog.md`](../../backlog.md#L265-L276)).
- OpenClaw has per-message token usage and vendor-computed cost, but also a second provider-shaped usage layer. The authoritative layer must be selected before summing ([`docs/backlog.md`](../../backlog.md#L223-L238)).
- Kimi has measured per-turn and session-rollup token records but no cost field ([`docs/backlog.md`](../../backlog.md#L202-L211)).
- Qwen has dense per-call counters in `systemPayload.uiEvent` and overlapping `usageMetadata`/session-rollup counters. It has no cost field; one layer must be selected to avoid double counting ([`docs/backlog.md`](../../backlog.md#L212-L222)).
- Grok has rich usage in `updates.jsonl`, which the current reader does not consume. Its cost is stored as `costUsdTicks` and needs scale calibration before displaying dollars ([`docs/backlog.md`](../../backlog.md#L277-L283)).
- fx has total input/output tokens in `session.json`, but not the component split needed for pricing ([`docs/backlog.md`](../../backlog.md#L284-L288)).
- Devin, Cursor, and Antigravity have measured negative results for local token/cost telemetry. These should remain unavailable until their storage formats change ([`docs/backlog.md`](../../backlog.md#L289-L319)).

### DeepSeek Harness track

DSH is now the seventeenth declared `SessionSource` case. Its merged history source is planned for 5.5, not yet deployed. Its first release remains a history browser: it includes local browsing/search/analytics and excludes live following, quota/cost telemetry, and resume ([DSH implementation plan](../plans/2026-09-18-dsh-source-implementation-plan.md#L9-L17)). The current descriptor marks telemetry `.allUnavailable("DeepSeek telemetry not yet audited")` until a real-store audit is complete ([source descriptor](../../../AgentSessions/DeepSeekHarness/DeepSeekHarnessSourceDescriptor.swift#L7-L12)). The validator accepts `usage` fields, but accumulator integration still waits for the post-5.5 audit.

This research did not audit a DSH live usage store and makes no claim about DSH live discovery, token fields, model attribution, or pricing. After 5.5, the next DSH task is to audit the `usage` fields accepted on assistant and LLM-call events against a real `~/.dsh/sessions` store, then connect only validated fields to a telemetry accumulator. Its changing storage formats, plain/Zstandard variants, and custom decoder requirements remain history-reader concerns first, not reasons to widen the Quota Meter rollout.

DSH is also not a current Session-Bench coverage row. That absence is not a negative telemetry result; it is another reason to keep DSH out of the live capability matrix until an audited corpus exists.

### Why OpenCode wins the next slice

The decision is based on evidence maturity, not a popularity contest. OpenCode has a large current local corpus, is used daily in the target workflow, already has a live-source path, and stores the per-message fields needed for a useful burn-rate. DSH has merged history support but no audited telemetry contract. OpenCode should therefore ship the first QM slice; DSH should proceed through the 5.5 history release and a separate post-5.5 usage audit.

## Capability definitions

### What “session” means

A session row is safe to show when there is a stable local identity and enough metadata to avoid presenting a history file as a currently running process. The minimum useful row is:

| Field | Meaning | Evidence required |
|---|---|---|
| Source | Codex, Claude, OpenCode, and so on | Parser or live-process source match. |
| Display name | User title, generated title, or a conservative fallback | Session metadata or live tab/title; never raw path alone when it is not user-recognisable. |
| Session ID | Provider/runtime ID | Durable record, presence registry, or a process-to-log join. |
| Surface | CLI, Desktop, VS Code, headless, or unknown | Explicit artifact marker, known root/sidecar contract, or controlled process evidence. |
| State | Working, idle, stale, or history-only | Registry/process/file activity with a TTL and explicit confidence. |
| Project | cwd/workspace | Session metadata or process cwd. |

Recent file modification is not, by itself, a live session. A transcript can be open in a viewer, can be written by a background sync process, or can have been abandoned. A live row needs a registry event or a process/session-log join.

### What “headless” means

Headless means an agent process is running without a controlling terminal. It does **not** mean “Desktop”. A no-TTY process must be classified using at least:

- executable/command path;
- app-bundle exclusion (`.app/Contents/...` is Desktop/app evidence, not CLI evidence);
- provider-specific invocation or process marker;
- session-log/cwd join when available.

The current shared admission rule already follows this shape: no-TTY processes are admitted only when an explicit headless PID allowlist contains them, while app-bundle executables are excluded ([`CodexActiveSessionsModel.swift`](../../../AgentSessions/Services/CodexActiveSessionsModel.swift#L3172-L3179), [`CodexActiveSessionsModel.swift`](../../../AgentSessions/Services/CodexActiveSessionsModel.swift#L3380-L3410)). The current `PresenceEngine` only builds and passes that allowlist for Claude; Codex and OpenCode therefore lose headless process fallback rows ([`PresenceEngine.swift`](../../../AgentSessions/Services/PresenceEngine.swift#L1157-L1173), [`PresenceEngine.swift`](../../../AgentSessions/Services/PresenceEngine.swift#L1185-L1222)). This is already recorded as an urgent backlog bug in [`docs/backlog.md`](../../backlog.md#L1377-L1401).

### What “pricing” means

There are three different numbers and they must not share one label:

1. **Native reported cost:** the agent/provider wrote a currency value into the local artifact. Pi, OpenClaw, OpenCode, and Hermes have evidence of this in their session stores.
2. **API-equivalent estimate:** QM applies a versioned model price table to component token counts. This is useful for comparison but is not an invoice. The current model explicitly calls it “API-equivalent” and says it is not actual subscription spend ([`SessionTelemetry.swift`](../../../AgentSessions/Model/SessionTelemetry.swift#L294-L318)).
3. **Subscription/included/account spend:** what the user will actually be billed or what is left in a plan. Local session tokens and a price table cannot establish this.

Cost must fail closed when a model, cache component, reasoning tier, or price revision is missing. The current calculator intentionally returns no dollar figure when one contributing component is unpriceable ([`TelemetryCostCalculator.swift`](../../../AgentSessions/Telemetry/TelemetryCostCalculator.swift#L50-L59), [`TelemetryCostCalculator.swift`](../../../AgentSessions/Telemetry/TelemetryCostCalculator.swift#L115-L125)). That policy should apply to every new source.

### What “live burn-rate” means

Presence alone is too weak for a live QM surface. The minimum useful live signal is a rate derived from observed session activity:

```text
tokens/hour = authoritative tokens observed in the rate window / active elapsed hours
API-equivalent $/hour = priced token components in the rate window / active elapsed hours
```

The denominator must be explicit. “Active elapsed” should advance between the first and latest accepted usage event, with an idle/quiet timeout or a provider activity marker; wall-clock time since process launch would make an idle session look artificially cheap. The UI should expose the window or freshness, for example `last 15m`, `since session start`, or `stale`.

The rate is a session burn-rate, not a quota forecast and not an invoice. It remains valid for included/subscription providers because the user can compare workload intensity even when the provider charges a flat plan. For a provider with native cost, `$ / hour` can use the native incremental cost. Otherwise it can use the same versioned API-equivalent price table already used by local telemetry. If only total tokens are known, show `tokens/hour` and leave dollars unpriced; do not price a total-only record with an invented input/output split.

The existing HUD model already carries an `aggregateTokensPerHour` value, but currently attaches it to dropped provider-limit entries and the compact Codex/Claude quota path ([`AgentCockpitHUDView.swift`](../../../AgentSessions/Views/AgentCockpitHUDView.swift#L2782-L2831), [`AgentCockpitHUDView.swift`](../../../AgentSessions/Views/AgentCockpitHUDView.swift#L3817-L3884)). That is evidence that the calculation concept exists, not evidence that all-agent live rows are covered. The research recommendation is to make the rate a first-class live-session snapshot rather than extending the quota-row assumptions.

### What “weekly quota” means

Weekly quota is an account-level provider window: remaining allowance, reset timestamp, source provenance, and account scope. It is not:

- tokens recorded in one local session;
- a price-table conversion;
- a rolling seven-day sum invented by QM;
- a monthly subscription name;
- a process rate multiplied by a guessed plan size.

Runway adds a further requirement: the quota window must be attributable to the current sessions well enough to answer “which session is consuming this window?” The current model marks weekly estimates as estimates and carries account-scope, reset, observation, and provenance fields ([`SessionTelemetry.swift`](../../../AgentSessions/Model/SessionTelemetry.swift#L350-L370)).

## Current all-agent matrix

Legend:

- **Now** means the current checkout can support the capability with existing code paths.
- **Candidate** means the local artifact contains enough evidence to justify a bounded reader/adapter, but the product path is not wired or needs a source-authority test.
- **Partial** means a number can exist but is not live, not complete, or not safely priceable.
- **No** means the measured local source has no trustworthy data or the capability is outside the current source contract.
- **Unknown** means the surface/provider question needs controlled evidence; it is not a negative claim.

### Presence and surface coverage

| Agent | Historical session row | Live row today | CLI/headless/terminal | Desktop/IDE | Product conclusion |
|---|---|---|---|---|---|
| Codex | Now | **Now, with headless gap** | CLI and headed terminal are identifiable; headless fallback is currently dropped without registry presence | Desktop is classified; VS Code is ambiguous because Codex Desktop also writes `source: vscode` | Show Codex quota plus live sessions; fix headless discovery before claiming completeness. |
| Claude Code | Now | Now | CLI and headless process path are supported | Desktop Code and Cowork/local-agent roots are read; cross-root joins are not fully certified | Show Claude quota plus local/cloud presence separately. |
| Antigravity | Now | Partial | CLI evidence exists; process fallback is TTY-biased | No Desktop artifact is proven | Sessions/presence only; no usage numbers. |
| OpenCode | Now | **Now, with headless gap** | TUI/CLI and official headless `serve`, `web`, and ACP modes exist; current app does not label the mode | Desktop/shared-store identity is unknown; current parser does not populate `surface` | Next vertical slice: fix headless admission, then show per-message components and token/hour; do not claim CLI vs Desktop parity yet. |
| DeepSeek Harness | **Merged for 5.5** | No | 5.5 history source covers local history only; live following is explicitly excluded | Ordinary root surface is unknown; live usage has not been audited | History in 5.5; audit usage after 5.5, but no current live row or QM telemetry claim. |
| Hermes | Now | No | Local CLI/session store, no live presence source | No separate Desktop artifact proven | History row now; token/cost candidate from SQLite. |
| Copilot CLI | Now | No | CLI/headless benchmark evidence | No Desktop row in current support contract | Completed-session summary only; no live meter. |
| Droid | Legacy only | No | Legacy imports only | None | Do not expand QM live coverage from Droid without a new verified source. |
| OpenClaw | Now | No | Local agent/CLI history; benchmark headless run was auth-blocked | No separate Desktop artifact proven | History row; candidate for tokens and native cost after authority choice. |
| Cursor | Partial | No | CLI/Agent stores are read | Desktop `state.vscdb` conversations are not discovered; surface attribution is unresolved | Do not claim all Cursor sessions; fix surface inventory first. |
| Pi | Now | No | CLI JSONL; live/active status explicitly unsupported | No Desktop artifact proven | History row with tokens/cost; no live row or quota. |
| Kimi Code | Now | No | CLI JSONL; live/active status unsupported | No Desktop artifact proven | History row; tokens-only candidate. |
| Grok CLI | Now | No | CLI JSONL/session directories | No Desktop artifact proven | History row; tokens candidate after sidecar reader, cost later. |
| Qwen Code | Now, but modern native evidence is blocked | No | CLI JSONL; live/active status unsupported | No Desktop artifact proven | History row and future tokens-only path; do not install or invent a modern capability claim. |
| Devin CLI | Now | No | CLI SQLite; live/active status unsupported | No Desktop artifact proven | Sessions only; measured telemetry is negative. |
| fx | Now | No | CLI checkpoint/session directories; live/active status unsupported | No Desktop artifact proven | Sessions plus possible token totals; no cost/quota. |
| Cline | Now | No | CLI and Desktop share the observed local session family | **Desktop is observed and separately versioned**; shared format, not separate telemetry | Sessions for both surfaces; live/usage remains unsupported. |

The surface classifications above are deliberately conservative. The benchmark’s cross-surface backlog says that a shared binary or marketing label is not sufficient; roots, artifacts, joins, and retention must be measured. The current app’s generic `SessionSurface` enum supports CLI, Desktop, VS Code, subagent, other, and unknown ([`Session.swift`](../../../AgentSessions/Model/Session.swift#L3-L23)), but `HUDRow` does not yet carry a surface field, so live rows need a separate surface-confidence path rather than a silent inference.

### Token, cost, quota, and runway coverage

| Agent | Tokens | Pricing | Weekly quota | Runway | Recommended QM presentation |
|---|---|---|---|---|---|
| Codex | **Now, partial:** current component records work; legacy total-only logs cannot be priced | API-equivalent estimate only; no native dollars in the log | **Now, estimated:** account-wide calibration; other-device activity is unobservable | **Now** for the existing Codex path | Provider quota row, runway, live session rows, token/hour, and API-equivalent `$ / hour`. Label estimated cost/quota. |
| Claude Code | **Now** per assistant usage | API-equivalent estimate only; no native dollars in the log | **Now, partial:** provider feed exists; stable account/session attribution is incomplete | **Now, partial** for local sessions; cloud is presence, not a per-session rate | Provider quota row; separate local/cloud presence; token/hour and API-equivalent `$ / hour` for local usage. Do not force cloud rows into rate-ranked runway. |
| Antigravity | **No:** measured transcripts contain no model, token, or usage fields | No | No local account feed | No | Session/presence metadata only. |
| OpenCode | **Candidate:** SQLite session and message rows contain component tokens; current descriptor/parser do not dispatch them | **Candidate:** local `cost` exists and `opencode stats` exposes token/cost stats; billing meaning depends on provider/plan | **No local feed today:** OpenCode Go/Zen may have plan or monthly limits, but the local session record does not prove remaining account allowance | No until an account window is authoritative | Live/session token total and token/hour; `$ / hour` when native/API price is complete, with provider/plan label. No fake quota. |
| DeepSeek Harness | **Not audited:** 5.5 history source keeps QM telemetry unavailable until a real-store usage audit | No | No | No | History ships in 5.5; post-5.5 audit of accepted `usage` fields comes before any accumulator or live row. |
| Hermes | **Candidate:** pre-aggregated SQLite columns | **Candidate/strong:** estimated/actual cost plus `cost_status`; included subscription must stay non-priceable | No | No | History/session token and cost detail; later live token/hour and `$ / hour` only if presence is added. |
| Copilot CLI | **Partial:** shutdown summary, not per-turn | **Partial:** summary pricing path; benchmark does not have dollar cost, only premium-request counters | No | No | Completed-session summary; no live token rate or quota. |
| Droid | No audited telemetry | No | No | No | Sessions only. |
| OpenClaw | **Candidate:** per-message usage and a second provider-shaped layer | **Candidate/strong:** vendor-computed dollars exist, but authority must be chosen | No | No | Tokens and native cost after dedup/authority tests; live token/hour if presence is added; no quota. |
| Cursor | **No:** measured local stores have no trustworthy token/cost fields | No | No | No | Sessions only; Desktop discovery is a separate prerequisite. |
| Pi | **Now** | **Now:** native `usage.cost` is recorded; current engine supports it | No | No | History/session token and cost detail; live token/hour and `$ / hour` only after presence is added; no quota. |
| Kimi Code | **Candidate:** measured per-turn/session records, no cost | No | No | No | Tokens only after choosing turn vs rollup and adding dedup tests. |
| Grok CLI | **Candidate:** sidecar has token usage, but current reader ignores it | **Not yet:** `costUsdTicks` needs scale calibration | No | No | Tokens after sidecar reader; hide dollars until scale is proven. |
| Qwen Code | **Candidate:** dense per-call counters, no cost | No | No | No | Tokens only after fresh-session authority/dedup verification. |
| Devin CLI | **No:** steward audit found zero usable token/cost telemetry | No | No | No | Sessions only; preserve the measured negative result. |
| fx | **Candidate:** total input/output only | No component split for safe pricing | No | No | Token totals only, once fresh steward evidence is available. |
| Cline | Not audited | Not audited | No | No | Sessions only until telemetry is measured. |

## OpenCode: detailed research result

OpenCode is the clearest next Quota Meter vertical slice. It is also the clearest case where “a free route or subscription exists” does not imply that Quota Meter can show `$0`, quota, or runway.

### What is confirmed

- OpenCode’s official CLI documents `opencode stats` as a command that shows token usage and cost statistics, with model/project/time filters ([OpenCode CLI docs](https://dev.opencode.ai/docs/cli/#stats)).
- The same CLI documentation exposes `opencode serve` and `opencode web` as headless server/web modes, plus ACP over ndJSON ([OpenCode CLI docs](https://dev.opencode.ai/docs/cli/#serve), [ACP section](https://dev.opencode.ai/docs/cli/#acp)). This makes “no terminal” a normal supported execution mode, not an exceptional process shape.
- OpenCode documents OpenCode Go as a subscription plan and Zen as a pay-as-you-go gateway. Zen publishes per-token prices and monthly usage-limit controls ([provider documentation](https://opencode.ai/docs/providers#opencode-go), [Zen pricing and limits](https://dev.opencode.ai/docs/zen#pricing)).
- The local SQLite store contains enough data for tokens and, on some records, cost. The current app preserves raw message JSON but does not decode the token/cost fields in `MessageJSON` ([`OpenCodeSessionParser.swift`](../../../AgentSessions/Services/OpenCodeSessionParser.swift#L34-L63)); the SQLite reader already loads every message row and retains its raw JSON ([`OpenCodeSqliteReader.swift`](../../../AgentSessions/OpenCode/OpenCodeSqliteReader.swift#L240-L295)).
- The model must be read from each `message.data.modelID`, not copied from the session-level model. A session can switch models, so each message is the unit for token totals, route classification, price lookup, and cost provenance.
- The local sample shows why a single token total hides the useful signal: input can substantially outweigh output. The live row should keep at least input, cache-read, cache-write/reasoning when present, and output as separate components.

### What is not confirmed

- There is no current local account-window adapter for OpenCode Go, Zen, xAI subscription, or the many BYO providers behind OpenCode.
- A token/cost record does not establish which plan pays for it. OpenCode can use Zen, Go, xAI subscription, direct API keys, or other providers. The model/provider fields must be carried with the usage record.
- OpenCode keeps a read-only local models catalog at `~/.cache/opencode/models.json`. In the current snapshot refreshed 2026-09-18, the `opencode` provider lists `muse-spark-1.3-contributor-free`, `deepseek-v4-flash-free`, and `big-pickle` with zero input/output/cache prices, while the paid siblings `muse-spark-1.3` and `deepseek-v4-flash` have published prices.
- `Free (promo route)` must come from the catalog, not from a `-free` suffix or a route-name special case. If every billable token price in the OpenCode catalog entry is zero, classify it as free. If the catalog file is missing, malformed, stale beyond the accepted freshness policy, or the route is absent, fail closed to `unpriced`; do not infer free from local `cost = 0`.
- A catalog-zero route with a named paid sibling can show a separate paid-sibling-equivalent estimate, clearly labelled as an estimate rather than actual spend. The sibling is not guaranteed to be the same model. A route with no paid sibling shows tokens/hour only.
- A shared SQLite store does not prove whether a row was produced by TUI, CLI, Desktop, `serve`, `web`, ACP, or another client. Surface attribution needs controlled paired probes.
- Live process discovery is currently incomplete for headless OpenCode, so even a correct token reader cannot show a current live row if the process never joins to the session database.

### Recommended OpenCode result

The safe first OpenCode surface is:

```text
OpenCode · session name · CLI/headless/unknown · model
Tokens: observed input / cache-read / cache-write / reasoning / output, with total as a secondary value
Rate: tokens/hour, calculated from accepted message timestamps and an explicit active-time window
Cost: catalog-derived paid-sibling equivalent per message when available; otherwise `Free (promo route)` or unpriced, with provenance
Quota: unavailable — provider plan/account window not observed locally
```

Do not show `OpenCode 0%`, `OpenCode $0`, or an OpenCode runway merely because the user is subscribed or a local row says `cost = 0`. A catalog-zero route may show `Free · ≈$X/h at <paid sibling> list price` only when the rate window is hourly and the sibling mapping is explicit; otherwise show tokens/hour only. A provider account adapter is intentionally out of the current rollout; first prove the local vertical slice end to end.

A paid-sibling calculation over a session snapshot is a session-equivalent estimate, not an hourly rate. The UI may turn it into `$ / hour` only after dividing by the accepted active-time window.

## Local API-equivalent pricing

The near-term API opportunity is a local price catalog, not a provider account integration. For OpenCode, the first source is OpenCode’s own `~/.cache/opencode/models.json`; for other providers, a separately versioned local manifest may be added later. The reader takes provider/model identity and observed token components from the local session record, then computes an explicitly labelled API-equivalent `$ / hour`. It does not read API keys, contact provider billing endpoints, or claim actual account spend. Missing, malformed, stale, or absent catalog entries fail closed.

| Provider or gateway | Local catalog opportunity | Safe boundary | QM recommendation |
|---|---|---|---|
| OpenAI API | Public model input/output prices; cache and special-mode entries where the manifest has complete component coverage ([official pricing](https://developers.openai.com/api/docs/pricing)) | A local Codex subscription session is not automatically OpenAI API usage. | Add price-manifest entries only for models and components that can be matched to local events. Defer OpenAI Usage/Costs account adapters. |
| Anthropic API | Input, cache write/read, and output pricing ([official pricing](https://platform.claude.com/docs/en/about-claude/pricing)) | Claude Code subscription usage must not be relabelled as Anthropic API spend. | Support local API-equivalent pricing after component mapping; defer account spend. |
| Gemini API | Model/tier pricing and token rates ([pricing](https://ai.google.dev/gemini-api/docs/pricing)) | Rate limits and free-tier status are not an actual spend value. | Treat as a later local catalog candidate; no Gemini billing adapter in this rollout. |
| OpenRouter | Model/provider price metadata where the local event preserves the gateway and upstream route | A model slug alone does not establish upstream provider, BYOK state, gateway fee, or actual account spend ([support](https://openrouter.ai/support), [BYOK](https://openrouter.ai/docs/guides/overview/auth/byok)). | Add only when route identity is recorded per message; defer credits and account adapters. |
| OpenCode Zen/Go | OpenCode already maintains a local provider catalog at `~/.cache/opencode/models.json`; it contains zero-priced routes, paid siblings, and cache-read prices. Zen has published token prices; Go is a subscription route ([providers](https://opencode.ai/docs/providers), [Zen](https://dev.opencode.ai/docs/zen)) | Local OpenCode cost does not prove which plan paid for the request. A zero catalog price means the route is free for estimate purposes, not that the account spent `$0`. | Read the catalog read-only during the OpenCode slice. Use `Free (promo route)` for a catalog-zero route, a paid-sibling-equivalent estimate only when the mapping is explicit, and tokens/hour alone otherwise. |

### Explicitly deferred: provider account adapters

OpenAI organization Usage/Costs, Gemini billing, OpenRouter credits, and similar account integrations are technically possible but out of the current QM plan. They require credentials, network permissions, account/project/key scope, refresh and stale-data UX, and ongoing provider maintenance. Keep them as a future research item, not a rollout dependency and not a “supported API” promise.

The near-term product boundary is therefore:

- local response/session usage only;
- public, versioned price manifests only;
- no secret scanning or credential discovery;
- no provider account spend, balance, quota, or credits;
- no actual `$ / hour` claim for a subscription or unknown promotional route.

## Surface matrix: what can be separated

### Strongly separable today

**Codex.** One source corpus can carry per-session CLI/Desktop labels. CLI and `exec` markers are trusted; `source: vscode` is ambiguous because Codex Desktop also writes it. A future separate Desktop/version row needs a controlled ordinary-repository comparison against the VS Code extension, not a path guess. The current classifier documents this directly ([`SessionIndexer.swift`](../../../AgentSessions/Services/SessionIndexer.swift#L2256-L2302)).

**Claude.** Standard CLI, Claude Desktop Code, and Cowork/local-agent roots are already known and scanned. The remaining issue is cross-root join/dedup certification: missing sidecars and duplicate IDs need fixtures before the surface label is treated as complete ([`docs/backlog.md`](../../backlog.md#L82-L107)).

**Cline.** The observed CLI and Desktop sessions share one two-file local format, but the verified versions are separate: CLI `3.0.62`, Desktop `0.0.28`. This is the cleanest current example of “separate Desktop version, shared artifact contract” ([`agent-support-matrix.yml`](../../agent-support/agent-support-matrix.yml#L298-L327)).

### Possible, but evidence is missing or incomplete

**OpenCode.** Officially has multiple modes, but the local record currently lacks a surface marker and the live process path is TTY-biased. Keep `surface = unknown` until a paired probe establishes a field/root/sidecar join.

**Cursor.** Desktop conversations in `state.vscdb` are measured locally but are not discovered. Some Desktop agent windows may also write the existing `~/.cursor` stores, so assigning all `state.vscdb` rows to Desktop would create false labels. The investigation and dedup requirement is recorded in [`docs/backlog.md`](../../backlog.md#L50-L80).

**Other agents.** The current support evidence is principally CLI/local-store evidence. That supports a history row, not a claim that a Desktop version does not exist. The correct label is “Desktop not evidenced” until a native artifact is inspected.

### Headed versus headless

The correct display model is two axes:

| Axis | Values | Meaning |
|---|---|---|
| Surface | CLI, Desktop, VS Code/IDE, other, unknown | Which user-facing host produced the artifact. |
| Terminal mode | headed terminal, headless/no TTY, app-managed, unknown | Whether a controlling terminal is present. |

`CLI + headless` is valid. `Desktop + no TTY` is also valid. `no TTY` alone is not enough to choose either. The presence row should preserve both values when evidence supports them.

## Weekly quota, tokens, and pricing: product rules

### Show weekly quota when all gates pass

A provider can receive a QM quota row only when all of these are true:

1. An authoritative provider/account response exists.
2. The response identifies the window and reset time.
3. The account or plan identity is stable across refresh/restart, or the UI explicitly says it is unscoped.
4. The response’s semantics are known enough to distinguish “no limit”, “not loaded”, “auth required”, and “zero remaining”.
5. Multiple local sessions can be joined to that account without silently attributing another account’s quota.
6. Staleness, rate limits, auth failure, and provider format drift have explicit UI states.

Today this is Codex and Claude only, with caveats. Codex’s descriptor says its quota is estimated from account-wide calibration and cannot observe other-device activity; Claude’s descriptor says raw quota exists but per-session attribution needs stable account identity ([Codex descriptor](../../../AgentSessions/Model/CodexSourceDescriptor.swift#L17-L25), [Claude descriptor](../../../AgentSessions/Model/ClaudeSourceDescriptor.swift#L16-L22)). A current backlog item also documents the unresolved Claude multi-account collision in weekly calibration ([`docs/backlog.md`](../../backlog.md#L1203-L1238)).

For every other source, the default display should be `quota unavailable` or no quota row. It must not be `0%`, `100%`, or a locally invented “week”.

### Show tokens when the local evidence gates pass

Token display needs less authority than quota, but it still needs correctness:

- choose one authoritative record family when a provider emits both per-turn and rollup counters;
- distinguish fresh input from cached input;
- include reasoning/cache/tool components only when semantics are known;
- deduplicate streaming snapshots and parent/child records;
- retain the source timestamp and session ID;
- update incrementally for SQLite/JSONL stores without reading an unbounded transcript on every tick;
- show `observed`, not `estimated`, when the provider wrote the count.

This is why Kimi, Qwen, OpenClaw, OpenCode, Hermes, Grok, and fx are viable token candidates even though they are not quota candidates.

### Minimum live output: tokens/hour, then `$ / hour`

For the new cross-agent live surface, the capability ladder should be:

1. **Presence:** source, session name, model, CLI/Desktop/headless classification, and live state.
2. **Tokens/hour:** the minimum usage signal once authoritative token events and timestamps exist.
3. **API-equivalent `$ / hour`:** preferred when the model/provider price and every billable token component are known.
4. **Native `$ / hour`:** preferred over an estimate when the local provider record reports incremental cost with known semantics.
5. **Account quota/runway:** optional and separate; never a gate for levels 1–4.

This changes the recommendation from “live sessions plus optional token totals” to “live burn-rate as the product value”. A row that has presence but no usable usage record remains useful, but it should be visibly a `presence-only` row rather than the target experience.

Rate display should be conservative:

- use a short rolling window when enough events exist, and show the window/freshness;
- fall back to a session-to-date rate only when the session start and usage authority are stable;
- reset or mark stale when the process/session join changes;
- do not extrapolate a weekly or five-hour runway from the rate;
- do not display `$ / hour` if a component is unpriced, the native currency field is uncalibrated, or the provider says the usage is included.

### Show pricing only with a pricing class

Suggested labels:

| Label | Meaning | Use |
|---|---|---|
| `Native cost` | Currency written by the provider/agent | Pi, OpenClaw, OpenCode, Hermes after source validation. |
| `API-equivalent` | QM applied a dated price manifest or provider catalog to observed token components | Codex/Claude and selected local API-backed models; OpenCode catalog routes; possibly fx or other BYO-key sources once components are complete. |
| `Free (promo route)` | OpenCode’s local catalog reports zero for every billable token price in the route entry | Do not infer from a suffix or local `cost = 0`. Show tokens/hour and components; if a named paid sibling is explicitly available, also show a separate paid-sibling-equivalent estimate. |
| `Included` | Provider says usage is covered by a plan/subscription | Show as included, not `$0`. Hermes already has this semantic. |
| `Unpriced` | Tokens exist but model/provider/rate/component is missing | Kimi, Qwen, fx initially; Grok until tick scale is calibrated. |
| `Unavailable` | No trustworthy local usage/cost evidence | Antigravity, Cursor, Devin, Cline today. |

The product should not expose an “actual spend” label for subscription or promotional sessions. The existing model’s `apiEquivalentUSD` name is the right semantic boundary. For the first all-agent live rollout, weekly and five-hour quota can be skipped entirely; they are an orthogonal provider capability and remain limited to the existing Codex/Claude paths. Provider account Usage/Costs/billing adapters are deferred, not part of this rollout.

## Business perspective

### User value

The broadest useful promise is not “we know every provider’s quota”. It is:

> See what agent work is running, where it is running, and what the local record says it has used.

That promise works for BYO-key agents, subscriptions, free/included models, and providers with no quota API. It also creates a useful path for users who do not care about quota but do care about live token/context growth.

### Product positioning

- **Quota Meter:** authoritative account windows and runway where supported.
- **Live sessions:** cross-agent operational visibility and burn-rate, independent of quota.
- **Usage detail:** observed tokens, model, cache/reasoning components, and cost provenance.
- **History:** all supported local session stores, including sources with no live process path.

This avoids making a subscription provider look broken because it has no local quota endpoint, and avoids making an API provider look equivalent to a subscription meter merely because both have token counts.

### Business risks

1. **False confidence:** a wrong quota or price number is worse than a missing number because users may stop work or misjudge spend.
2. **Support burden:** every vendor format drift becomes a customer-visible telemetry defect, not just a transcript parser issue.
3. **Provider policy:** account quota/billing adapters may require network calls, OAuth scopes, cookies, plan-specific endpoints, or terms review. That is materially different from local read-only session parsing, so those adapters are deferred.
4. **Privacy:** session names, cwd, model/provider IDs, and account identity can be sensitive. Live presence should stay local and should not send transcript content.
5. **Surface confusion:** users may assume a “Desktop” label means a different billing bucket. For some agents it is only a different client writing the same local artifact.
6. **Pricing drift:** model rates, cache semantics, long-context tiers, and included plans change. Every estimate needs price-manifest identity and date.
7. **Rate illusion:** a session that is alive but idle can make `$ / hour` or `tokens/hour` look artificially low unless the denominator and quiet-period policy are visible.

### What not to promise

- “All agents have quota meters.”
- “Tokens equal dollars.”
- “A zero cost means free.”
- “A session file changed recently, so the agent is running.”
- “No TTY means Desktop or no TTY means headless CLI.”
- “The same database root proves the same surface.”
- “The benchmark score proves live detection or billing correctness.”

## Steward and maintainer work

### What a steward is responsible for

The steward contract is narrow: one agent, one installation, and a periodic format check against their own sessions. It explicitly excludes code, review duty, support rota, and sharing raw transcripts ([`STEWARDS.md`](../../../STEWARDS.md#L1-L26)). The format-sweep plan says every active source has one verification owner, and a missing steward-owned CLI is expected rather than a reason to install it or lower support claims ([format-sweep plan](../plans/2026-08-31-format-sweep-automation-PLAN.md#L35-L50)).

A steward check can establish:

- the current session format and schema drift;
- whether the parser’s existing artifact contract still holds;
- a redacted sample, when the tool safely produces one;
- whether a new field or artifact family exists.

A steward check cannot by itself establish:

- provider account quota semantics;
- actual billing or subscription balance;
- that a token field is authoritative across overlapping record families;
- that a process is live or headless on another machine;
- that a Desktop surface shares the CLI store;
- permission to send external messages or change product scope.

### Where a steward ask is valuable

| Priority | Agent | Ask | Why |
|---|---|---|---|
| High | OpenCode | Fresh redacted samples from headed CLI/TUI, headless `serve`/one-shot, and any Desktop client; record version, process path, session ID, SQLite row shape, and whether `opencode stats` agrees with local fields | Resolves live headless identity, surface separation, usage authority, and cost semantics in one candidate. |
| High | Cursor | Paired Desktop/Agent/IDE sessions with changed-file manifests and stable IDs | Desktop conversations are currently missing and path-only attribution can duplicate or mislabel rows. |
| Medium | Hermes | Fresh state.db session with `cost_status`, `billing_provider`, included/subscription case, and token columns | Confirms the existing rich column contract and prevents “included = $0”. |
| Medium | OpenClaw | Fresh session containing both usage families, with a comparison against the agent’s own summary | Selects the authoritative usage layer and prevents double counting. |
| Medium | Kimi | Fresh session with `usageScope=turn` and `usageScope=session` records | Pins the turn-vs-rollup authority and token convention. |
| Medium | Qwen | Fresh authenticated native transcript with `ui_telemetry` and `usageMetadata` together | Confirms the current field names and selects one authority; no cost is expected. |
| Medium | Grok | A session bundle including `updates.jsonl` and `summary.json` | Enables token extraction and calibrates `costUsdTicks` before any dollar label. |
| Medium | fx | A session written by the currently claimed version with `session.json` totals | Confirms token totals and keeps the steward/version claim honest. |
| Low | Cline | A CLI and Desktop pair with any usage metadata, if the user wants live/usage expansion | Current support intentionally claims sessions only; no need to expand without demand. |
| Low | Copilot | A real subagent session comparing top-level shutdown usage, `agentMetrics`, and `subagent.completed` | Current summary may undercount subagent usage; fixture evidence is insufficient. |

### Where not to ask a steward

- Do not ask stewards to discover or provide provider quota endpoints.
- Do not ask them to install an absent agent or buy a subscription solely for a QM experiment.
- Do not ask them to send raw transcripts, screenshots, account IDs, API keys, or billing pages.
- Do not use a steward’s absence of local sessions as evidence that the provider format is unsupported.
- Do not turn a normal format check into an unannounced live-process or network telemetry study.

There is an ownership inconsistency worth resolving before any Qwen outreach: the human [`STEWARDS.md`](../../../STEWARDS.md#L82-L106) table lists Qwen as “steward wanted”, while the format-sweep contract treats Qwen as a maintainer-owned/unavailable exception and says not to create a steward draft ([plan](../plans/2026-08-31-format-sweep-automation-PLAN.md#L93-L105), [plan tests](../plans/2026-08-31-format-sweep-automation-PLAN.md#L488-L500)). Until that is reconciled, the safe action is neither an automatic poke nor a local paid-plan experiment.

### Current ownership routing

Based on the current human steward table and the machine-readable matrix:

- **Maintainer-owned:** Codex and Claude.
- **Steward-verified:** Devin and fx, with @thedavidweng evidence; fx still needs a fresh native-version check for newer claims.
- **Best effort / steward wanted:** Cursor, Copilot, OpenCode, Antigravity, Pi, Kimi, Grok, OpenClaw, Hermes, Qwen, and Cline.
- **Legacy-only:** Droid; it is intentionally outside active format monitoring and has no steward.

This is format ownership, not an assignment to build QM adapters. A token or quota feature may need maintainer/product decisions even when a steward supplies the raw format evidence.

## Technical research recommendation

### Candidate data contracts

Do not force every agent into `UsageTrackingSource` or `CodexRunwaySnapshot`. A separate live-session contract should allow absent capabilities:

```text
LiveSession
  source
  sessionID
  displayName
  model
  surface
  terminalMode
  liveState
  workingDirectory
  lastActivity
  sourceConfidence
  tokenSnapshot?
  tokenRate?
  costSnapshot?
  burnRateSnapshot?
  priceSource?
  quotaSnapshot?
```

Each optional snapshot needs provenance and status, not just an optional number:

```text
TokenSnapshot: observed | unavailable | stale | ambiguous
CostSnapshot: native | apiEquivalent | freePromo | included | unpriced | unavailable
BurnRateSnapshot: rolling | sessionToDate | stale | insufficientData | unavailable
PriceSource: openCodeCatalog | localPriceManifest | nativeRecord | none
QuotaSnapshot: authoritative | estimated | stale | authRequired | unavailable
Surface: cli | desktop | vscode | subagent | unknown
TerminalMode: headed | headless | appManaged | unknown
```

This keeps “a live OpenCode session with tokens” valid without requiring a quota object, and keeps “a Claude cloud session is present” valid without inventing a per-session rate.

### Read strategy by artifact family

- JSONL: maintain an incremental file cursor and deduplicate by stable event/record ID; never sum both cumulative and delta families.
- SQLite: use a bounded read-only transaction, query `time_updated`/message IDs, and read WAL-safe state; do not treat a session-level aggregate and per-message details as additive until proven.
- Sidecar bundles: define the primary/companion join and missing-companion behavior before showing a row.
- Process discovery: use explicit command/app-bundle classification and a session-log/cwd join; TTY is metadata, not identity.
- API-backed usage: use only usage already captured in the agent’s local response/event record for this rollout; do not contact provider account APIs.
- Provider quota: keep separate from local transcript parsing and record account, window, reset, provenance, auth state, and staleness.

### Validation required before exposing a number

For each candidate source, the research gate should answer:

1. What is the authoritative record family?
2. Does the total reconcile with provider-reported total, if present?
3. Are cache, reasoning, tool, and compaction tokens included or separate?
4. Are streaming snapshots superseded or additive?
5. Does a parent session include child usage?
6. Does a Desktop/headless client write the same artifact family?
7. Can a restarted app rediscover the same identity without network access?
8. What does an included/subscription cost status mean?
9. If an API-equivalent price is shown, is the number based on a local price manifest and complete per-message components?
10. What is the honest UI state when a field is absent or ambiguous?

No source should be promoted from “candidate” to “supported” based only on a model name, one synthetic fixture, a current file size, or a provider marketing page.

## Suggested rollout order (not an implementation plan)

1. **OpenCode vertical slice — presence:** fix the headless Codex/OpenCode admission gap, with regression cases for no-TTY CLI, app-bundle exclusion, registry/process dedup, and session-log identity.
2. **OpenCode vertical slice — usage:** decode authoritative per-message SQLite usage and preserve input, cache-read, cache-write/reasoning, and output separately. Read `message.data.modelID` for every message; do not use the session model as the pricing key.
3. **OpenCode vertical slice — live rate:** compute and display `tokens/hour` from accepted message timestamps and an explicit active-time window. Compare totals and components with `opencode stats`; keep quota unavailable.
4. **OpenCode vertical slice — pricing state:** read `~/.cache/opencode/models.json` read-only; classify a route as `Free (promo route)` only when its catalog entry has zero billable prices, use a paid-sibling-equivalent estimate when the mapping is explicit, and fail closed when the catalog is missing or the route is absent. Never render local `cost = 0` as `$0.00/h` or `Included` without catalog evidence.
5. **Generalize only after the slice works:** extract the smallest reusable live/burn-rate contract from the working OpenCode path, rather than designing a horizontal all-agent framework first.
6. **Add other local price catalogs later:** OpenCode already has a provider catalog; for other providers, add only routes whose per-message components and public prices match exactly. Do not add provider Usage/Costs, billing, credits, or balance adapters in this phase.
7. **DSH history track:** ship the history source in 5.5. After that release, audit the validator-accepted `usage` fields against a real store, then consider a telemetry accumulator; do not fold this into the OpenCode slice.
8. **Other local telemetry candidates:** Hermes/OpenClaw native cost; Kimi/Qwen tokens-only; fx tokens-only; Grok after tick calibration. Each remains behind source-authority and fresh-format evidence, not behind a generic framework milestone.

## Final decision table

| Question | Research answer |
|---|---|
| Can QM show just session names and source for all agents? | Yes for all agents with readable indexed history; for current live rows, only when presence is proven. History-only sources should not be presented as running. |
| Can CLI be separated from Desktop? | Yes where the artifact or controlled process/root evidence says so: Codex, Claude, and Cline have meaningful evidence. OpenCode and Cursor need paired probes. Others remain unknown/CLI-only until tested. |
| Can headless CLI without a terminal be shown? | Yes. It needs an explicit headless/process or registry path. Current Codex/OpenCode process fallback has a confirmed bug. |
| Can we show live tokens without quota? | Yes. This is the recommended OpenCode path and is also technically viable for Hermes, OpenClaw, Kimi, Qwen, Grok, fx, and selected local API-backed model records after source-authority evidence. |
| Is a live sessions list enough? | No. Presence is the identity layer; the minimum useful live usage signal is `tokens/hour`, with `$ / hour` preferred when native or API-equivalent pricing is complete. |
| Can we show API-backed models? | Yes, locally: preserve response/session usage and apply a public, versioned price manifest. Provider Usage/Costs/account data is deferred. |
| Can we show pricing? | Sometimes. Use native cost, a labelled API-equivalent estimate, catalog-derived `Free (promo route)`, or unpriced; never present subscription/included/unknown promotional usage as actual dollars. |
| Can we show weekly or five-hour quota for all agents? | No, and it is not required for the new live surface. Keep those windows only for provider integrations that pass the account, reset, identity, and attribution gates; today that is Codex/Claude with caveats. |
| Can we show runway for all agents? | No. Runway requires quota, reset semantics, account identity, and session attribution. Tokens alone are insufficient. |
| Where does DSH belong? | History-source track. The history source ships in 5.5; after 5.5, audit validator-accepted `usage` fields against a real store before considering a telemetry accumulator. |
| Do stewards own this work? | No. They can verify local formats and provide redacted evidence. They do not own quota semantics, billing interpretation, code, or product decisions. |
| What is the strongest next feature? | One end-to-end OpenCode Live burn-rate slice: headless admission, per-message component usage, model-aware aggregation, and `tokens/hour`; generalize only after it works. |

## Sources consulted

### Local repository

- [`SessionSource.swift`](../../../AgentSessions/Model/SessionSource.swift)
- [`SessionSourceDescriptor.swift`](../../../AgentSessions/Model/SessionSourceDescriptor.swift)
- [`SessionTelemetryEngine.swift`](../../../AgentSessions/Telemetry/SessionTelemetryEngine.swift)
- [`SessionTelemetry.swift`](../../../AgentSessions/Model/SessionTelemetry.swift)
- [`TelemetryCostCalculator.swift`](../../../AgentSessions/Telemetry/TelemetryCostCalculator.swift)
- [`PresenceEngine.swift`](../../../AgentSessions/Services/PresenceEngine.swift)
- [`CodexActiveSessionsModel.swift`](../../../AgentSessions/Services/CodexActiveSessionsModel.swift)
- [`OpenCodeSessionParser.swift`](../../../AgentSessions/Services/OpenCodeSessionParser.swift)
- [`OpenCodeSqliteReader.swift`](../../../AgentSessions/OpenCode/OpenCodeSqliteReader.swift)
- [`docs/superpowers/plans/2026-09-18-dsh-source-implementation-plan.md`](../plans/2026-09-18-dsh-source-implementation-plan.md)
- [`docs/superpowers/plans/2026-08-30-dsh-source-PREP.md`](../plans/2026-08-30-dsh-source-PREP.md)
- [`docs/backlog.md`](../../backlog.md), especially Agent Source Coverage, Cross-Surface Session Storage, Usage Tracking, and the urgent headless presence entry
- [`docs/agent-support/agent-support-matrix.yml`](../../agent-support/agent-support-matrix.yml)
- [`STEWARDS.md`](../../../STEWARDS.md)
- [`docs/superpowers/plans/2026-08-31-format-sweep-automation-PLAN.md`](../plans/2026-08-31-format-sweep-automation-PLAN.md)

### Local machine evidence

- `~/.cache/opencode/models.json`, read-only snapshot refreshed 2026-09-18; OpenCode entries for `muse-spark-1.3-contributor-free`, `muse-spark-1.3`, `deepseek-v4-flash-free`, `deepseek-v4-flash`, and `big-pickle`.

### Benchmark and provider documentation

- [Session-Bench repository](https://github.com/jazzyalex/session-bench)
- [Session-Bench cross-surface backlog](https://github.com/jazzyalex/session-bench/blob/main/BACKLOG.md)
- [OpenCode CLI reference](https://dev.opencode.ai/docs/cli/)
- [OpenCode provider documentation](https://opencode.ai/docs/providers)
- [OpenCode Zen pricing and limits](https://dev.opencode.ai/docs/zen)
- [Pi session format](https://pi.dev/docs/latest/session-format)
- [Pi session stats/RPC](https://pi.dev/docs/latest/rpc#get_session_stats)
- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- [OpenAI organization Usage and Costs reference](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage)
- [OpenAI API CLI authentication reference](https://developers.openai.com/api/reference/cli)
- [Anthropic API pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [Anthropic Messages API usage](https://platform.claude.com/docs/en/api/http/messages)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [OpenRouter support and usage/billing](https://openrouter.ai/support)
- [OpenRouter BYOK](https://openrouter.ai/docs/guides/overview/auth/byok)
