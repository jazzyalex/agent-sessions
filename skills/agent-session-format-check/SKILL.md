---
name: agent-session-format-check
description: Verify agent session format compatibility for Agent Sessions. Use when any agent CLI updates, when monitoring flags drift, or when bumping max verified versions (fixtures + docs + tests). Covers session schema, usage/limits tracking, storage backends, and discovery path contracts for all supported agents.
---

# Agent Session Format Check

Answer one precise question for every supported agent:

> Can current Agent Sessions code support the latest available session/storage/usage
> format from the latest available agent build?

The answer must be layered. Do not collapse version checks, stale samples, schema
fingerprints, discovery contracts, and usage probes into a vague severity label.

**Evidence-first:**
- Gather a report + sample paths first.
- Do not change parsers/fixtures/docs without explicit user approval.

**Related skill:** `agent-support-matrix` — maintains the matrix YAML, ledger, and
update-checklist workflow. This skill focuses on *detection and evidence collection*;
`agent-support-matrix` focuses on *recording and gating version bumps*.

**Process doc:** `docs/agent-support/monitoring.md` — defines the compatibility verdicts,
legacy severity model, cadence, and escalation workflow that feed into this skill.

---

## 1  Quick Start (all agents)

1. Run weekly monitoring:
   ```
   ./scripts/agent_watch.py --mode weekly
   ```
   Report path prints to stdout and is written under
   `scripts/probe_scan_output/agent_watch/*/report.json`.

2. In `report.json`, check each agent under `results.<agent>`:
   - `compatibility.verdict`, `compatibility.scope`, `compatibility.blockers`,
     and `compatibility.next_action`
   - `verified_version`, `installed.parsed_version`, `upstream.parsed_version`
   - `compatibility.latest_status` to distinguish `current_fetch_known`,
     `cached_latest`, and unknown latest-source states
   - `weekly.local_schema` (newest local session used for fingerprinting)
   - `weekly.schema_diff` and `evidence.schema_matches_baseline`
   - `evidence.sample_freshness` and `evidence.fresh_evidence_source`
   - `compatibility.latest_real_session_failure` when a prebump attempt failed
   - `severity` and `recommendation` only as legacy escalation fields

3. **Usage / limits reading (Codex + Claude) — always verify every weekly run.**
   These drift independently of session schema (see §2), so a clean schema does
   **not** imply healthy usage reading. Each agent's
   `results.<agent>.weekly.probes` is a **list**; for every relevant entry confirm
   `ok == true` and `exit_code == 0`:
   - Codex — `label == "codex_status_probe"` (parse `codex_status_json`): the
     active CLI status channel (`five_hour`, `weekly` percent-left). The passive
     channel is the session JSONL `token_count` / `rate_limits` events, covered by
     the schema fingerprint above.
   - Claude — `label == "claude_usage_probe"` (parse `claude_usage_json`): the
     **authenticated** `/usage` reading (`session_5h`, `week_all_models`,
     `week_opus`). Also `label == "claude_status"` (parse `claude_status_json`):
     status.claude.com indicator/incidents.
   A failed or unparsed usage probe is a usage-format or auth regression even when
   versions match and the session schema is clean — never skip it, and report each
   probe's `ok` explicitly rather than collapsing it into the compatibility verdict.

4. **Classify every new field for value, not just for safety (§1e).** A field that parses
   cleanly is *safe*, which is not the same as *handled*. Do not close a drift finding
   until each new key or type has been called noise, watch, or feature-candidate — and
   candidates filed in `docs/backlog.md`, not left as a remark in the ledger.

Interpretation:
- `supports_latest`: latest known build is covered by
  `evidence.fresh_evidence_source == "latest_prebump_report"` and
  `compatibility.latest_real_session_evidence == true` with
  `compatibility.latest_status == "current_fetch_known"`.
- `supports_installed_only`: installed build is covered by non-stale real local
  evidence, but latest is newer, cached from a prior report, unknown, or lacks
  fresh real-session proof.
- `latest_unknown`: no configured/reachable latest source or no real-session
  driver exists; do not claim latest support.
- `blocked_stale_sample`: evidence predates the installed CLI; run prebump before claiming support.
- `blocked_no_fresh_evidence`: a version changed but no fresh matching sample proves support.
- `format_drift_detected`: unknown schema/storage/usage fields appeared; update fixtures/parsers.
- `blocked_thin_sample`: the sample was both narrow and tiny, so it evidenced nothing either
  way (§5a). Generate a session that actually uses tools — not a one-line prompt.
- `monitoring_broken`: latest source, usage probe, or discovery contract failed.
- `real_session_auth_failed` in blockers: the real-session driver ran but the
  sandboxed agent was not authenticated; re-auth or provide the configured env
  token, then rerun prebump.

---

## 1a  Real-Session Prebump Validation (required before latest claims)

Weekly scanning samples the newest on-disk session, which can predate a CLI
upgrade and give a false "safe to bump" call (the codex 0.120.0 trap and the
copilot `session.shutdown` trap). When weekly reports
`recommendation == run_prebump_validator` — or before you stage any
`max_verified_version` bump or latest-support claim — run the prebump path for
every active agent being claimed. The driver exercises the currently installed
CLI once inside a sandbox and diffs its output against the fixture baseline:

```
./scripts/agent_watch.py --mode prebump --agent codex --agent claude
```

Exit-code contract:
- `0` — every requested agent produced a fresh session and the schema
  matches baseline. Safe to bump.
- `2` — at least one fresh session's schema does **not** match baseline.
  Do **not** bump; investigate the schema diff in
  `scripts/probe_scan_output/agent_watch/<slug>-prebump/report.json`.
- `3` — at least one driver failed (timeout, auth, CLI not found, or
  discovery contract violation — wrong session root, wrong glob, or
  missing required event types).
- `4` — config/invariant error: unknown `--agent` (or one with no
  prebump block), missing/invalid `discover_session` contract,
  credential hygiene failure (oversize / mode), or sandbox breach
  (copilot hermeticity gate). Re-run with
  `--allow-real-home` only if you understand your real config dir will
  be mutated for that one invocation.

Flags:
- `--agent <name>` (repeatable) — restrict to specific agents. An
  unknown agent or one without a `prebump` config block exits 4.
- `--keep-sandbox` — preserve the temp `$HOME` for debugging.
- `--timeout-seconds N` — per-driver timeout. CLI flag overrides
  per-agent config; falls back to config, then global default (120s).
- `--force-fresh` — suppress staleness evaluation for this run only (records
  `stale_reason=forced_fresh` in the report).
- `--allow-real-home` — copilot/real-HOME opt-in after a sandbox-breach
  diagnostic; never persistent.

**A thin prebump can no longer downgrade a rich weekly union.** A passing prebump
*replaces* the weekly `schema_diff` with its own one-prompt session, and the thin-sample
gate used to score only that: on 2026-08-13 codex reported `blocked_thin_sample` off a
20-event prebump while its weekly union carried 2808 clean events — adding evidence made
the verdict worse. `_sample_is_thin()` is now applied to *every* available sample and only
blocks when all of them are thin (pinned by `test_thin_prebump_does_not_override_rich_weekly_union`).

**Give `real_home_session` agents a tool-using prompt.** Their prebump session lands in the
real store and enters the newest-`_LOCAL_SCHEMA_SAMPLE_COUNT` window, so a "Say hello"
prompt actively degrades the next weekly sample — two such runs pushed antigravity's union
down to 24 events and a genuine `blocked_thin_sample`. Claude's `"Say hi, then use the Bash
tool to run pwd."` is the pattern; verify any prompt change with a real run, since a
tool-using prompt can hang or return nothing on CLIs whose one-shot mode does not complete
a tool turn.

**A passing prebump is a floor, not a ceiling.** Drivers use one-line prompts, so a fresh
session may contain only the four most basic event types and still report
`fresh_matches_baseline=True` — it proves the CLI still writes parseable output, not that
rich event families are unchanged. For `real_home_session: true` agents that session also
lands in the real store and becomes the newest sample; §5a's multi-session union is what
stops it from masking drift. Check the fresh session's type count before treating a pass as
broad evidence.

Configured real-session drivers today are `codex`, `claude`, `antigravity`,
`copilot`, `opencode`, `hermes`, `openclaw`, `cursor`, `pi`, `kimi`, and `grok`.
Droid is legacy-only and excluded from active checks. Qwen has no driver — it
reports `no_real_session_driver_configured` and can never claim `supports_latest`;
judge it on the weekly schema diff instead. That is not a gap to fill with code:
Qwen's OAuth free tier was discontinued 2026-04-15, so no session can be generated
at all until a paid plan or alternate provider is configured (see §1c).

**Staleness short-circuits the schema verdict.** `blocked_stale_sample` is reported
*instead of* drift, so a stale agent can be hiding real drift behind it. Kimi sat at
`blocked_stale_sample` while every one of its sessions carried two unmodelled event
types; building its driver surfaced them immediately. Treat a stale verdict as
"unknown", never as "clean".

Prebump uses the hybrid env-var-first auth policy: if the relevant API-key
env var (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
`FACTORY_API_KEY`, `GITHUB_TOKEN`) is set it is forwarded into the sandbox
and real HOME is never read. Otherwise the driver copies the declared
credential file from real HOME into the sandbox after running three hygiene
gates (64 KiB max, mode `0600`, ≤90-day mtime warning). v1 drivers:
`codex_exec`, `claude_print`, `antigravity_print`, `copilot_prompt`,
`opencode_run`, `hermes_oneshot`, `openclaw_local_agent`,
`cursor_agent_print`, `pi_prompt`, and `kimi_prompt`. Some OAuth/keychain-backed CLIs use
`real_home_session: true`; run them with `--allow-real-home` so the session
lands in the real agent store instead of copying single-use auth state into a
sandbox.

---

## 1b  Claiming a Newer Upstream Build (install → fresh session → verify → bump)

**A version bump is never just a YAML edit.** `max_verified_version` claims that the
app parses sessions *written by that build*, and the only thing that can prove it is a
session that build actually wrote. So when `upstream.parsed_version` is newer than
`installed.parsed_version`, the sequence is fixed:

```
1. Install the newer CLI (its own updater, brew, or npm — whatever owns it).
2. ./scripts/agent_watch.py --mode prebump --agent <name>     # writes a FRESH session
3. Confirm exit 0 and fresh_matches_baseline == true.
4. Only now bump max_verified_version + ledger + tracking log (§6).
```

**Step 2 is not optional, and skipping it makes the report actively worse.** Installing
an update rewrites nothing on disk: the newest session is still the one the *old* build
wrote, so it is now older than the CLI binary and the agent flips from
`supports_installed_only` (a real claim, backed by real evidence) to
`blocked_stale_sample` (which per §1a means *unknown*, never *clean*). That is why the
2026-08-13 pass deliberately did **not** install Hermes 0.19.0: without a working
one-shot run to generate a fresh session, updating would have destroyed a verdict it
could not replace. Install only if you can complete step 2.

**An agent with no prebump driver cannot do this loop at all.** It is permanently capped
at `supports_installed_only`, however clean its weekly looks, because nothing can produce
a session from a build on demand. Build the driver first — `grok_single` (added
2026-08-17) is the worked example, and see §1d for what building one involves.

**Re-read the installed version after the run.** Several CLIs self-update *because* the
prebump invoked them — copilot, cursor and antigravity all did on 2026-08-13 — so the
build you validated may not be the build you started with. Bump to what the post-run
report says is installed, not to what you intended to install.

---

## 1c  When an Agent Cannot Produce a Session At All

Some agents are blocked for reasons no driver can fix, and the distinction matters
because it decides whether there is engineering work to do:

- **Fixable, ours** — a broken install. OpenCode sat at `installed=unknown` with an
  `Exec format error` that read like a driver bug; `/opt/homebrew/bin/opencode` was
  actually the npm package's *shell stub*, because its postinstall never ran. Run
  `file $(which <agent>)` before suspecting anything schema-shaped.
- **Fixable, theirs** — a broken agent config. OpenClaw and Hermes both fail on borrowed
  backends that are misconfigured in the user's own environment (§ledger 2026-08-13).
- **Not fixable by us** — the account or plan is gone. Qwen's OAuth free tier was
  discontinued **2026-04-15**; `qwen -p` returns "Run /auth to switch to Coding Plan,
  OpenRouter, Fireworks AI, or another provider," and `qwen auth` is itself "(removed)"
  in 0.21.x. No driver, re-login, or fixture can produce a session. Record the verdict
  honestly as `blocked_stale_sample`, say why in the matrix, and stop — it is a billing
  decision for the maintainer, not a task.

Do not let category three masquerade as category one. A missing driver looks like
engineering work right up until you try to authenticate.

---

## 1d  Building a Prebump Driver

Drivers live in `scripts/agent_watch_prebump_drivers.py` and register into `DRIVERS`;
their config block is `agents.<name>.prebump` in `agent-watch-config.json`. Copy the
nearest existing driver rather than starting from the Protocol.

Non-obvious requirements, each learned from a real failure:

- **Declare `discover_session` with the modern `roots`/`globs`/`required_types` keys.**
  The config gate rejects anything else with exit 4, and the runtime validator then
  proves the driver returned the artifact it claimed rather than some other file.
- **Check the agent is in `MATRIX_KEY_FOR_AGENT`** (`scripts/agent_watch.py`). A missing
  entry does not error: `baseline_paths` comes back empty, the diff takes its
  "no baseline → nothing diffs" branch, and the prebump reports
  `fresh_matches_baseline=true` **having compared nothing**. `grok` was missing from the
  prebump copy of that map on 2026-08-17 while present in the weekly copy, so its first
  driver would have passed vacuously. The map is now single-sourced and pinned by
  `test_every_monitored_agent_is_registered_in_the_rebuild_tool`.
- **Prefer an API-key env var; fall back to a credential file.** `prepare_auth` is the
  only auth path — never build env from `os.environ` inside a driver. Some agents have no
  key env var at all (grok's only documented one is `GROK_SANDBOX`), so the credential
  copy is their sole route and the 0600 hygiene gate always applies.
- **Give it a tool-using prompt**, and for `real_home_session: true` agents especially —
  their session lands in the real store and enters the newest-5 weekly window, so a
  "Say hello" prompt degrades next week's sample (§1a).
- **If a session is a directory, verify the sidecars before returning ok.** Grok's
  `summary.json` is a discovery precondition; returning a transcript whose sidecar never
  landed hands the fingerprinter half a session and reports the gap as schema drift.

Then verify the driver the way you would verify a finding: run it, confirm
`baseline_type_count` in the report is non-zero (proving a baseline was consulted), and
confirm the fresh session actually contains a tool call rather than four trivial events.

---

## 1e  The Value Pass (what new fields are *for*, not just whether they break us)

This check has a structural blind spot, and it is worth stating plainly: it asks only
*"does it still parse?"* Because the parsers read JSON as dictionaries, the answer is
almost always yes — an unknown key is never read, an unknown type falls to a `default:`
branch and becomes a `.meta` event. So every finding exits the funnel as "no parser
change needed," which is true and also the end of the thought. **Nothing ever asks
whether upstream just started telling us something a user would want to see.**

The cost is not hypothetical. Kimi's `turn.ended.durationMs` was noted in the
2026-08-13 ledger as "the natural source of a per-turn duration UI" and then sat there,
because a ledger note is a remark, not work. And Qwen shipped with
"usage/rate-limit tracking" listed as an *unsupported surface* while every one of its
transcripts carried full per-call token accounting — 53 records in one ordinary session.
The data was never missing. Nobody opened it.

**So classify every new key or type into exactly one of three buckets, and record which:**

| Bucket | Meaning | Action |
|---|---|---|
| **noise** | internal plumbing, ids, or telemetry nobody would look at | fixture only; say so once so it is not re-litigated |
| **watch** | meaningful but not actionable yet — a field that will matter if it starts appearing widely, or that only one source emits | fixture + a line in the ledger note |
| **candidate** | carries information a user would want on screen | fixture **+ an entry in `docs/backlog.md`** |

Cheap heuristics for spotting a candidate: it is a **number a user would ask about**
(tokens, cost, duration, context size), it **names something currently anonymous** (which
connector ran this tool, which model, which provenance), or it **records a state
transition the UI hides** (mode changes, rewinds, compaction).

Two rules that keep this honest:

- **Check the value before believing the matrix.** `unsupported_surfaces` describes what
  the *app* does, never what the *agent emits*. Qwen's entry made a present surface look
  absent for a full release. When a value pass contradicts a matrix line, the matrix line
  is the thing that is wrong.
- **Measure before promoting.** Claude's `budget_usd` carries real dollars and looked like
  a free replacement for the estimated-cost path — until counting showed it in 2 of 410
  recent sessions, because it only appears when a budget is set. Confirm how often a field
  actually occurs, and on which record types, before filing it as a candidate.

Candidates go in `docs/backlog.md` under the matching area section, using that file's own
entry format, with **verified** stamped to the date of the sweep that found them. A format
check should end with two outputs: a clean bill of health, and a short list of things
upstream started telling us that we are not yet using.

---

## 1f  Steward Check (what a community steward runs)

Each agent has a steward: a contributor who uses that agent daily and re-verifies
its format a few times a year, or after a big vendor release. A steward is not
expected to know any of the above. They run one command:

```
./scripts/steward_check.py <agent>       # ./scripts/steward_check.py --list-agents
```

It runs the ordinary weekly scan (§1) restricted to that one agent, against the
steward's own local sessions, and answers in plain sentences with one of three
exits:

- **0 — all good.** `all good: <agent> format matches the baseline (N sessions
  sampled)`, plus the matrix's verified version. If their CLI is newer than the
  verified version and the schema still matches, it says the matrix entry can be
  bumped — that is the §1b evidence a maintainer needs.
- **1 — drift.** The schema diff in plain words, a **redacted** sample written to
  `scripts/probe_scan_output/steward_check/<agent>/redacted-sample/`, and a
  ready-to-paste GitHub issue body (also saved as `issue.md`).
- **2 — cannot check.** The CLI is not installed, there are no sessions on disk,
  or the repository has no baseline fixtures for that agent yet. Says which.

What it deliberately does **not** do: write or rebuild any baseline fixture.
Deciding that drift is real and rebuilding a baseline stays a maintainer job
(`scripts/rebuild_stage0_baseline.py --agent <agent> --emit`, §5a/§7).

The sample reuses `rebuild_stage0_baseline._redact` — the same trimming that
produces committed fixtures — and then re-scans the result for home directories,
emails, key-shaped strings, IPs and long opaque ids. **If anything survives, the
sample is withheld entirely** and the issue body says so; a steward is never
handed an almost-clean file to paste into a public issue.

Maintainer side of the same command: when a steward's issue arrives, its sample
is already in fixture shape, so it drops straight into
`Resources/Fixtures/stage0/agents/<agent>/` for a baseline rebuild. Verify the
redaction yourself anyway before committing (§7).

---

## 2  Usage / Limits Drift (Codex + Claude)

Usage and limits tracking can drift **independently** of session schema. Monitor both.

### Codex
- **Passive channel:** session JSONL `token_count` / `rate_limits` event structure. This is
  covered by the schema fingerprint **only because codex is fingerprinted nested** (§5a) —
  these events live under `event_msg.payload`, and the flat fingerprint that ran until
  2026-08-03 stopped at `{payload,timestamp,type}` and could never see them. If codex is
  ever moved back to the flat fingerprint, this channel goes unwatched again.
- **Active channel (weekly):** `codex_status_capture.sh` output schema — parsed as
  `codex_status_json` by `agent_watch.py`.
- Check: in `results.codex.weekly.probes` (a list), the entry with
  `label == "codex_status_probe"` returns `ok == true` and `exit_code == 0`.
  If not, investigate whether Codex changed its status output format.

### Claude
- **Active channel (weekly):** `claude_usage_capture.sh` output schema — parsed as
  `claude_usage_json`.
- **Context probe:** `./scripts/claude-status --json` records status.claude.com
  indicator/incidents (parsed as `claude_status_json`).
- Check: in `results.claude.weekly.probes` (a list), the entry with
  `label == "claude_usage_probe"` returns `ok == true` — if `false`, the usage API
  response format may have changed, or authentication may be required. The
  `label == "claude_status"` entry (parse `claude_status_json`) reports
  status.claude.com indicator/incidents.
- If probe health fails (`parsing_failed`, auth required, etc.), treat as **high severity**
  because the UI can break.

### Known issue: Claude usage probe exit 16 (parsing_failed)
`claude_usage_capture.sh` can fail with exit 16 when Claude auth tokens are exhausted.
The `/usage` TUI command itself stops working in this state. This is **not** a format
change — resolution requires `claude auth login`. The failure is intermittent and clears
after re-authentication. The Swift side silently retains the last known good snapshot.

### What to look for in upstream release notes
- New or renamed fields in usage/billing/token responses.
- Auth changes (new scopes, cookie rotation, API key requirements).
- Rate-limit header changes or new quota enforcement mechanisms.

---

## 2a  Model Price Freshness (Session Runway `$` burn)

The runway's `$` presentation prices per-type token rates against a model table, so it
drifts whenever a provider changes prices or ships a model slug we don't know — with no
schema change and no failing probe. Nothing else in this scan catches it. Unlike a
broken probe, **stale prices fail silently**: the number still renders, just wrong.

**Sources of truth (fetch these, don't recall them):**
- Anthropic — <https://platform.claude.com/docs/en/about-claude/pricing>
- OpenAI — <https://developers.openai.com/api/docs/pricing>

**The table lives in two places that MUST stay identical:**
- `docs/prices.json` — served to clients from GitHub Pages (corrects shipped apps with
  no release)
- `RunwayPriceTable.bundledJSON` in `AgentSessions/CodexStatus/RunwayPriceTable.swift`
  — the compiled-in default (offline / pre-first-fetch)

### Checks
1. **Prices unchanged?** Compare every key's `inputPerMTok` / `cachedInputPerMTok` /
   `outputPerMTok` / `cacheWritePerMTok` against the official pages. Anthropic cache
   columns are derived: read = 0.1x input, 5m write = 1.25x input.
2. **New model slugs?** Any tier we don't have a key for is **dropped from `$`** (it
   still shows in `tk/h`), so a new model silently disappears from the cost view.
   Check what the local CLIs actually emit rather than guessing:
   ```bash
   # Codex: the model lives on turn_context lines
   grep -ho '"model":"[^"]*"' ~/.codex/sessions/$(date +%Y/%m)/*/*.jsonl | sort -u
   # Claude: message.model on assistant lines
   find ~/.claude/projects -name '*.jsonl' -mtime -7 -print0 \
     | xargs -0 -n1 jq -r 'select(.type=="assistant") | .message.model' 2>/dev/null | sort -u
   ```
   Every slug returned must resolve via longest-prefix against a table key.

   **Known slugs that look alarming but are fine** (verified 2026-07-14):
   - `<synthetic>` (Claude) — not a model. It appears on assistant lines and does
     carry a `usage` object, but every field is **0**, so it forms a zero-rate
     component and `dollarsPerHour` skips it. Do NOT "fix" this by adding a price
     key; the zero-rate exemption is what keeps it from dropping the whole session.
     If Claude ever gives `<synthetic>` real tokens, that exemption stops applying
     and every Claude session would vanish from `$` — re-check this if it changes.
   - `codex-auto-review` (Codex) — Codex's internal auto-review label, on `turn_context`.
     It bills **real** tokens, and because an unpriced *contributing* slice makes
     `dollarsPerHour` return nil for the whole session, a missing key here didn't
     understate the cost — it deleted the session from `$` entirely. Priced at the
     gpt-5.6/sol default since 2026-08-03. This is the failure mode to look for whenever
     a session is missing from `$`: check for a slug with no key before anything else.
   - `gpt-5.6-codex` (Codex) — no key of its own; resolves to the `gpt-5.6` fallback
     (sol pricing). OpenAI publishes no separate `-codex` rate, so that is the best
     available assumption. The bare `gpt-5.6` key exists for exactly this.
3. **Prefix collisions?** Keys match by longest prefix, so a shorter key must never
   shadow a longer one, and a legacy key must never capture a current slug (e.g.
   `claude-opus-4-1` must NOT match `claude-opus-4-8`). Adding a bare `claude-opus-4`
   would break exactly this. `testPriceTableLegacyKeysPriceWithoutShadowingCurrent`
   and `testPriceTableBundledAndPrefixMatch` pin it — run them after any table edit.
4. **Temporary pricing expired?** Introductory/promo rates have end dates. Known:
   Claude Sonnet 5 intro $2/$10 ends **2026-08-31** (we deliberately bundle the stable
   $3/$15, so nothing breaks at expiry).

### Updating
Edit `docs/prices.json`, mirror the identical change into `bundledJSON`, and **always
advance `updated`**. Clients only accept a manifest whose `updated` is `>=` their
bundled table's, so a forgotten bump means the correction is ignored — that date is the
only thing preventing a stale cache from shadowing corrected prices. Pushing
`docs/prices.json` corrects already-shipped apps within a day, with no release.

Verify: `xcodebuild test -scheme AgentSessions -only-testing:AgentSessionsTests/CodexUsageParserTests`

### Cadence
Monthly is enough — provider prices move rarely, but when they move they move a lot
(Opus went $15/$75 → $5/$25, a 3x overstatement that ran undetected). Also check on any
**new model launch**, since an unknown slug drops that session from `$` entirely.

---

## 3  OpenCode Storage Changes

OpenCode's current local backend is SQLite at `~/.local/share/opencode/opencode.db`.
Legacy installs may still have a multi-file JSON tree (`storage/session/`,
`storage/message/`, `storage/part/`). Monitoring is SQLite-first and falls back to
the legacy JSON tree when no database is present.

### Current layout
```
~/.local/share/opencode/opencode.db

# legacy fallback
~/.local/share/opencode/storage/session/<project>/ses_*.json
~/.local/share/opencode/storage/message/<sessionId>/msg_*.json
~/.local/share/opencode/storage/part/<messageId>/*.json
```

### What to watch for
- **New storage backends:** OpenCode is a Go application. Watch upstream releases for
  introduction of SQLite, BoltDB/bbolt, Badger, or other embedded databases alongside or
  replacing the JSON file tree.
- **Schema changes in any record type:** session, message, or part records can evolve
  independently. The fingerprinter tracks keys per record kind.
- **New record types or directories:** a new sibling to `session/message/part` would
  indicate a storage expansion.
- **Migration flags:** look for `version`, `migration`, `schema_version` fields in
  session records or new migration files in the OpenCode repo.

### Detection in agent_watch.py
- `opencode_storage_latest_session` checks `db_roots` first and fingerprints
  `session`, `message`, and `part` rows from `opencode.db`.
- If no database is present, `_opencode_storage_session_tree_schema_fingerprint()`
  walks the legacy JSON tree for a session and reports keys per record kind.
- Risk keywords in `agent-watch-config.json` still flag release notes mentioning
  storage migrations such as SQLite, BoltDB/bbolt, Badger, or database changes.

---

## 3a  Cursor Storage

Cursor uses two storage backends:

- **JSONL transcripts** (`~/.cursor/projects/<workspace>/agent-transcripts/<uuid>/<uuid>.jsonl`) — primary session data, parsed by Agent Sessions. Subagent transcripts live in a `subagents/` subdirectory.
- **SQLite chat databases** (`~/.cursor/chats/<workspace-hash>/<uuid>/store.db`) — supplementary metadata (session name, model, timestamps). Key "0" in the `meta` table contains hex-encoded JSON.

The weekly scan fingerprints JSONL transcripts only. The SQLite probe (`cursor_sqlite_probe.py`) verifies the `meta` table is readable — it does not deep-fingerprint the database schema.

**What to watch for:**
- New top-level keys on `role: user/assistant` lines.
- New content block types beyond `text`, `tool_use`, `tool_result`, `thinking`.
- The `agent-transcripts/` directory being renamed or moved.
- SQLite probe failures indicating `meta` table schema changes.

**Note:** Some machines may have a stale PATH shim for `cursor` even when Cursor.app is installed. The weekly monitor tries the PATH command first, then falls back to the embedded app CLI at `/Applications/Cursor.app/Contents/Resources/app/bin/cursor --version`.

Cursor CLI latest-source truth comes from the official installer script at
`https://cursor.com/install`, which embeds `downloads.cursor.com/lab/<build>/...`
agent CLI package URLs. The Homebrew `cursor-cli` cask page is a fallback. Do
not use the unrelated npm package named `cursor-agent`.

Cursor Desktop agent windows use the same local surfaces as Cursor CLI:
`~/.cursor/projects/*/agent-transcripts/**/*.jsonl` for transcript content and
`~/.cursor/chats/*/*/store.db` for chat metadata. The weekly
`cursor_sqlite_probe` must keep reporting the newest Desktop chat DB's
`agentId`, `createdAt`, mode/model fields, mtime, and meta-key schema so fresh
Desktop-only windows are visible even when their JSONL transcript is absent or
older.

---

## 4  Discovery Path Contracts

Each agent has a `discovery_path_contract` in `agent-watch-config.json` defining the
expected file layout Agent Sessions uses to discover sessions. If an upstream agent moves
or renames its storage, discovery breaks even if the parser still works.

Weekly monitoring checks these contracts. When a contract fails:
- `severity` escalates to `high`.
- The session viewer will silently stop finding new sessions for that agent.
- Investigate whether the agent changed its storage location or naming convention.

Key contracts (simplified from regexes in `agent-watch-config.json`):
| Agent    | Expected pattern |
|----------|-----------------|
| Codex    | `*/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Claude   | `~/.claude/projects/**/*.{jsonl,ndjson}` |
| OpenCode | `*/opencode/storage/session/*/ses_*.json` |
| Hermes   | `~/.hermes/sessions/session_*.json` |
| Antigravity | `~/.gemini/antigravity/brain/<conversation-id>/*.md` |
| Copilot  | `~/.copilot/session-state/*.jsonl` |
| OpenClaw | `*/agents/<id>/sessions/*.jsonl` |
| Cursor   | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` |
| Grok     | `~/.grok/sessions/<enc-workdir>/<sessionId>/chat_history.jsonl` |

### `required_companion_files` — sidecars discovery refuses to work without

A contract may also declare `required_companion_files`, a list of paths resolved
**relative to the sampled transcript's own directory**. Each entry is either a bare
string (existence is enough) or `{path, must_parse, note}`, where
`must_parse: "json_object"` additionally requires the file to load as a JSON object.
A breach fails the whole contract, so it lands as `severity: high`,
`verdict: monitoring_broken`, and a `probe_or_discovery_failed` blocker — the same
escalation as a moved store.

Declare one whenever the app's discovery **guard chain** refuses a session over a file
that is not the transcript. The schema fingerprint structurally cannot cover this: a
sidecar that fails to load simply contributes no keys, and `_schema_diff` ignores
`missing_keys`/`missing_types` on purpose (a thin sample legitimately lacks baseline
types — that is what `coverage_ratio` is for). Sibling-union sampling then erases even
that trace, because the other four sampled sessions refill the bucket. Verified on a
copy of the real Grok store with one sidecar hidden: `unknown_types: []`,
`unknown_keys: {}`, `unknown_only_is_empty: true` — a *total* discovery outage reporting
as no drift. Never expect the schema channel to catch a missing companion file.

---

## 4a  Grok Sessions Are Directories

A Grok session is a directory, not a file: `chat_history.jsonl` holds the transcript and
the sibling `summary.json` holds everything discovery depends on (`info.id`, `info.cwd`,
`current_model_id`, `chat_format_version`). Fingerprinting only the transcript would leave
that half unwatched, so `_grok_session_schema_fingerprint()` merges the summary in as a
`summary` bucket — schema diffs on `summary`/`summary.info` are summary.json drift, not
transcript drift.

**The sidecar is a discovery precondition, not a schema nicety.**
`GrokSessionDiscovery.discoverSessionFiles()` skips any session directory whose
`summary.json` is absent, so losing that one file removes *every* Grok session from the
app. Merging it into the fingerprint does not protect it — see §4
`required_companion_files`, which is what actually flips the verdict. Grok declares it
with `must_parse: "json_object"`, deliberately stricter than the app's own `fileExists`
guard: a present-but-corrupt sidecar still lists the session but strips its id, cwd,
title and both timestamps. `_grok_session_schema_fingerprint()` also records a
`summary_error` (`missing` / `unreadable` / `invalid_json` / `not_json_object`) so the
fingerprint stops pretending it read a sidecar it could not.

**Grok's parser is now tolerant like the other twelve.** `GrokSessionParser` used to
decode `summary.json` through a `Codable` struct, so one field arriving with a new type
threw and `try?` dropped the *whole* sidecar — id, cwd, title, model and both timestamps
at once. It reads `JSONSerialization` dictionaries field by field now, so vendor
additions are ignored keys and a changed field costs exactly that field. Drift is
therefore an alert here (this scan), never a crash — pinned by
`GrokSessionParserTests.testUnknownNewFieldsAreIgnored` and
`testSidecarFieldOfTheWrongTypeCostsOnlyThatField`.

Grok is fingerprinted **nested** (§5a). Flat would stop at `{type, content, ...}` and hide
the content-part types (`user.content:text`, `user.content:image`) and
`backend_tool_call.kind.action`, which is where its format actually moves. `arguments` is
opaque — it is a tool's parameter object, not Grok format.

The baseline is **two** session directories: `grok/` (top-level) and `grok/subagent/`.
That split is deliberate — `session_kind` appears *only* on subagent sessions and is
absent from top-level ones, so stamping it on the top-level fixture would have taught the
inverted semantics to anything that later classifies on it. Keys that belong to one kind
go in that kind's fixture; the baseline unions both.

**Latest version comes from two sources that disagree.** Grok ships a native x.ai binary
through the `grok-build` Homebrew cask, and the cask lags x.ai releases. The
`grok_update_check` probe declares `latest_version_key: "latestVersion"`, and
`_reconcile_latest_version_from_probes()` takes the **higher** of cask and CLI — max, not
replace, because the CLI answers only for its own pinned `channel`, so a lower CLI answer
must never hide a newer published release. The chosen number's origin is in
`upstream.parsed_version_provenance` (`cli_probe` / `upstream_source` / `both_agree` /
`cached_prior_report`), the full comparison in `upstream.reconciliation`, and any
disagreement prints on the weekly summary line as
`latest_disagree=probe:<v>/source:<v>/used:<v>`. Never read `upstream.parsed_version`
without its provenance.

Still unwatched: `subagents/<childId>/meta.json` — the parent's sidecar, and the only
place `parent_session_id` and `subagent_type` appear, so the hierarchy feature depends on
it (the `grok/subagent/` fixture is a subagent *session*, not that sidecar) — and the
`compaction/` subtree. No fixture covers either yet. Also unwatched: the app's 50 MB
`defaultFullParseMaxBytes` ceiling, above which `GrokSessionParser` silently declines to
parse a transcript, and a wholesale move of the `~/.grok/sessions` root, which surfaces
only as `local_schema.error: no_files_found` plus a stale sample rather than as a named
contract failure (`discovery_contract_failed` is gated on a file having been found).

---

## 5a  How the Fingerprint Works (and what it cannot see)

Read this before trusting a clean `unknown_types=[]`.

**Nested vs flat.** `_schema_fingerprint_for_agent()` in `scripts/agent_watch.py` is the one
place that decides depth. Codex, Copilot and Claude use `_nested_jsonl_schema_fingerprint`
(depth 3); Kimi uses its own loop-event walker; everyone else is flat. Baseline and observed
sample always go through this same function — fingerprinting one side flat and the other
nested diffs two different alphabets.

Lists are **unioned across every element** (capped at `_NESTED_LIST_SAMPLE_LIMIT`), not
sampled by their first item. Claude's `message.content` mixes text/thinking/tool_use blocks,
so first-item-only made later block types invisible — the exact drift the nesting exists to
catch.

Two rules keep nesting from manufacturing drift:
- **`_NESTED_OPAQUE_KEYS`** — keys whose values are open-ended maps. Codex's
  `patch_apply_end.changes` is keyed by absolute file path; descending into it invents a
  bucket per edited file *and writes real user paths into report artifacts*. Copilot keys
  `modelMetrics` by model id. Add a key here rather than accepting the noise.
- **The `:type` discriminator applies only at the payload wrapper** (depth 0→1), where the
  real event union lives (`event_msg.payload:token_count`). Deeper, `type` tags enum-like
  config variants (`sandbox_policy:read-only`), and splitting on those makes an ordinary
  settings change look like schema drift.

Claude's opaque keys are `input` and `toolUseResult` — both are TOOL-defined payloads, not
Claude format, so walking them would make every new tool read as schema drift.

**Still flat:** OpenClaw, Pi, Droid, plus the bespoke Hermes/OpenCode/Cursor/Kimi
fingerprinters. Their payload interiors are unwatched; nothing has been lost to that yet,
but the same blind spot applies in principle.

**Multi-session sampling.** Weekly fingerprints the newest `_LOCAL_SCHEMA_SAMPLE_COUNT` (5)
sessions and unions them. This exists because sampling one session let whichever session was
newest decide the verdict — a 4-line "Say hello" prebump session, left in the real store by
`--allow-real-home`, once flipped antigravity from `format_drift_detected` to clean with the
drift still sitting in a 92KB session two files back. When `required_types` is configured,
sibling sampling **must** honour it (`_newest_files_with_types`): OpenClaw's `**/*.jsonl`
glob otherwise sweeps in audit logs and an embedded codex-home and reports codex's event
types as OpenClaw drift.

**`blocked_thin_sample`** fires only when a sample is *both* narrow (<50% of baseline types)
and tiny (<25 events). Coverage alone is not enough: baselines deliberately contain rare
interactive-only families (`ai-title`, `pr-link`, `permission-mode`) that a perfectly healthy
1000-event session will never contain.

**Never build a fixture from a handful of recent sessions.** Rare families are rare, so a
5-session sample misses them by construction and the weekly then reports "drift" every time
one surfaces — alerts that mean *our baseline was incomplete*, not *upstream changed*. On
2026-08-04 that gap was 13 of 24 Claude attachment subtypes and 9 of 18 Codex `event_msg`
families. Rebuild from every session on disk instead:

```
./scripts/rebuild_stage0_baseline.py --agent claude          # report the gap
./scripts/rebuild_stage0_baseline.py --agent claude --emit   # append redacted coverage
```

It sweeps all discoverable sessions, greedily harvests the fewest real records that close
the gap, and redacts every scalar (only `type`/`role`/`subtype`/`model` survive, because
those *are* the schema). **Read its report before `--emit`**: a bucket keyed by a UUID, path
or header name is a free-form map that belongs in `_NESTED_OPAQUE_KEYS`, not in the fixture.
That is how `collab_waiting_end.statuses` (keyed by thread id) and `system.error.headers`
(keyed by HTTP header, carrying `set-cookie`) were caught.

**Baseline semantics.** `_baseline_type_keys_for_agent()` excludes `*schema_drift*` fixtures.
So once a drifted type is verified and handled, it belongs in the **normal** baseline fixture
— otherwise it re-reports as drift every week forever (Copilot's `session.auto_mode_resolved`
and `session.usage_checkpoint` did exactly that from 2026-07-22 until 2026-08-03).
`schema_drift.jsonl` is for adversarial/speculative shapes only.

---

## 5  What to Collect as Evidence

Alongside the report fields below, record the **value-pass ruling** (§1e) for every new
key or type: noise, watch, or candidate. A finding is not closed until it has one, and
candidates are not closed until they are in `docs/backlog.md`.


From the weekly report (all agents):
- The path in `results.<agent>.weekly.local_schema.file` (newest session).
- The schema diff summary: `unknown_types`, `unknown_keys` (additive drift),
  `missing_types`, `missing_keys` (may mean "not observed in this sample").
- Probe results and `ok` status for usage probes.
- Discovery path contract pass/fail status.

Optional (recommended when a bump is needed):
- Copy the newest session file(s) into `scripts/agent_captures/<timestamp>/<agent>/`.
- Keep captures private (do not commit raw sessions; they can contain paths and prompts).

---

## 6  Verification Update Checklist (after approval)

1. **Refresh fixtures** for the affected agent under `Resources/Fixtures/stage0/agents/<agent>/`.
   Put verified-and-handled types in the **normal** fixture, not `schema_drift.jsonl` — see §5a.
   Make the fixture a **superset** of the old key sets; silently dropping keys shrinks the baseline.
2. Ensure fixtures include the "important" event families when present:
   - Session metadata / `session_meta` payload keys.
   - Tool call / tool result events.
   - Usage/limits events (`token_count`, `rate_limits`, billing) when emitted.
   - Optional event wrappers (compaction, context, delta events) when present.
   - For OpenCode: representative session, message, and part JSON files.
3. Bump the verified version record — **only after a session written by that build
   exists** (§1b). If the version you are bumping to is newer than what is installed,
   stop and run the install → prebump → verify loop first; a bump with no fresh session
   behind it is an unbacked claim, and installing without generating one regresses the
   agent to `blocked_stale_sample`.
   - `docs/agent-support/agent-support-matrix.yml` (`agents.<key>.max_verified_version`)
   - Append a new entry in `docs/agent-support/agent-support-ledger.yml`
   - Add a line to `docs/agent-json-tracking.md` under "Upstream Version Check Log"
4. Run tests locally:
   ```
   xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions \
     -destination 'platform=macOS' test
   ```
5. Run discovery-contract tests:
   ```
   ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests
   ```

---

## 7  Redaction Guardrails (fixtures)

When turning a real session into a committed fixture:
- Replace long instruction bodies with a short placeholder string (keep structure).
- Remove or truncate large base64/data-url blobs if present.
- Prefer keeping only minimal, deterministic message text (e.g., "List the files").
- Keep the schema shape intact: do not delete keys just because values were redacted.
- For OpenCode multi-file fixtures: redact each file independently but preserve
  cross-file references (session ID in message paths, message ID in part paths).
