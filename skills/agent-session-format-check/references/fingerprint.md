# Format-check reference: fingerprint

The [runbook](../SKILL.md) governs authority and run order. Historical incidents below
explain the checks; they do not authorize sign-ins, purchases, commits or releases.

Current corrections (2026-11-02): Hermes SQLite weekly now unions five sessions.
All local schema results carry store_sessions, sampled_sessions, sampled_events and
sampled_versions; writer versions come from recorded headers/rows, never PATH.
store_count_scope names the configured schema-discovery candidate scope. OpenCode's
version cohort and the steward-owned Devin topology probe declare single-session
reasons; an unexplained one-of-many sample fails the discovery/monitoring gate.
The gated production replay currently covers Codex, Claude and OpenCode only. Its
counts distinguish missing usage from malformed usage; no-usage probe sessions and
refusal-only OpenCode sessions are expected and still require explicit explanation.

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

**So classify every new key or type into exactly one of four buckets, and record which:**

| Bucket | Meaning | Action |
|---|---|---|
| **handled** | current code already reads the field for a user-visible or integrity path | cite the code and a behavior test; refresh the normal fixture, but do not file duplicate work |
| **noise** | internal plumbing, ids, or telemetry nobody would look at | fixture only; say so once so it is not re-litigated |
| **watch** | meaningful but not actionable yet — a field that will matter if it starts appearing widely, or that only one source emits | fixture + a line in the ledger note |
| **candidate** | carries information a user would want on screen | fixture **+ an entry in `docs/backlog.md`** |

Cheap heuristics for spotting a candidate: it is a **number a user would ask about**
(tokens, cost, duration, context size), it **names something currently anonymous** (which
connector ran this tool, which model, which provenance), or it **records a state
transition the UI hides** (mode changes, rewinds, compaction).

Two rules that keep this honest:

- **Prove `handled`, do not infer it from a similar field name.** Cite the read path and a
  test whose behavior depends on the new shape. A parser's tolerant fall-through or raw
  JSON retention means safe, not handled.
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

## 4  Discovery Path Contracts

Each agent has a `discovery_path_contract` in
`docs/agent-support/agent-watch-config.json` defining the
expected file layout Agent Sessions uses to discover sessions. If an upstream agent moves
or renames its storage, discovery breaks even if the parser still works.

Weekly monitoring checks these contracts. When a contract fails:
- `severity` escalates to `high`.
- The session viewer will silently stop finding new sessions for that agent.
- Investigate whether the agent changed its storage location or naming convention.

Key contracts (simplified from regexes in
`docs/agent-support/agent-watch-config.json`):
| Agent    | Expected pattern |
|----------|-----------------|
| Codex    | `*/sessions/YYYY/MM/DD/rollout-*.jsonl` or cold `rollout-*.jsonl.zst` (§2b) |
| Claude   | `~/.claude/projects/**/*.{jsonl,ndjson}` |
| OpenCode | `*/opencode/opencode.db` or legacy `*/opencode/storage/session/*/ses_*.json` |
| Hermes   | `~/.hermes/state.db` or legacy `~/.hermes/sessions/session_*.json` |
| Antigravity | `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` (CLI) or the same under `~/.gemini/antigravity/brain` (desktop app 2.25.0+; older IDE conversations there keep `*.md` only) |
| Copilot  | `~/.copilot/session-state/*.jsonl` or `*/events.jsonl` |
| OpenClaw | `*/agents/<id>/agent/openclaw-agent.sqlite` (2026.10.5+, zstd rows decoded) or legacy `*/agents/<id>/sessions/*.jsonl`; never `agent/codex-home/` (embedded Codex harness) |
| Cursor   | `~/.cursor/projects/*/agent-transcripts/**/*.jsonl` |
| Pi       | `~/.pi/agent/sessions/**/*.jsonl` |
| Kimi     | `~/.kimi-code/sessions/wd_*/session_*/agents/main/wire.jsonl` |
| Grok     | `~/.grok/sessions/<enc-workdir>/<sessionId>/chat_history.jsonl` |
| Qwen     | `*/projects/<project>/chats/<id>.jsonl` or `chats/archive/<id>.jsonl` |
| Devin    | `~/.local/share/devin/cli/sessions.db` |
| fx       | `~/.fx/sessions/<id>/checkpoint.json` (schema 3, ≤0.0.7) or `<id>/events.jsonl` (schema 4, 0.0.8+; only with no checkpoint and no `authority.json`); `session.json` companion required; `v2/` skipped |

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

## 5  How the Fingerprint Works (and what it cannot see)

Read this before trusting a clean `unknown_types=[]`.

**Nested vs flat.** `_schema_fingerprint_for_agent()` in `scripts/agent_watch.py` is the one
place that decides depth. Codex, Copilot, Claude, Grok, and Qwen use nested fingerprints
(depth 3); Kimi and several storage-backed agents use bespoke fingerprint functions;
remaining JSONL agents are flat. Baseline and observed sample always go through this same
function — fingerprinting one side flat and the other nested diffs two different alphabets.

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

Claude's opaque keys include `input` and `toolUseResult` — both are TOOL-defined payloads,
not Claude format, so walking them would make every new tool read as schema drift. Qwen's
`function_args` is opaque for the same reason. Read `_NESTED_OPAQUE_KEYS` for the complete
current list rather than copying it into this skill.

**Still flat or bespoke:** OpenClaw, Pi, Droid, Hermes, OpenCode, Cursor, Kimi, Devin, and
fx do not use the generic nested walker. Their format-specific fingerprint functions may
intentionally inspect deeper storage records, but any payload interior they do not expose
remains a blind spot. Verify the adapter before assuming either flat or nested coverage.

**Multi-session sampling.** Weekly fingerprints the newest `_LOCAL_SCHEMA_SAMPLE_COUNT` (5)
sessions and unions them. This exists because sampling one session let whichever session was
newest decide the verdict — a 4-line "Say hello" prebump session, left in the real store by
`--allow-real-home`, once flipped antigravity from `format_drift_detected` to clean with the
drift still sitting in a 92KB session two files back. When `required_types` is configured,
sibling sampling **must** honour it (`_newest_files_with_types`): OpenClaw's `**/*.jsonl`
glob otherwise sweeps in audit logs and an embedded codex-home and reports codex's event
types as OpenClaw drift.

**Prebump-written sessions are skipped.** `_prefer_real_sessions` takes the newest
`_LOCAL_SCHEMA_SAMPLE_COUNT` *real* sessions and adds prebump sessions, newest first, only
when fewer real ones exist. `_is_prebump_session_file` decides per session, from signals
already in the session:
- an `AGENT_WATCH_PREBUMP_<32 hex>` marker in the session head (antigravity, copilot;
  hermes reads it from the first user message in `state.db`);
- a `"cwd"` in the head inside an `agent-watch-prebump-<agent>-…` sandbox (cline's manifest);
- that sandbox name in the session's own path, where the store encodes the cwd into a
  directory name (cursor project dirs, deepseek_harness project keys);
- the agent's configured `prebump.prompt` in the head (claude, whose driver has no marker
  and runs in the repo, not a sandbox);
- an OpenClaw `session_windows.session_key` containing `:prebump-`.

Only the head is read (first 8 JSONL lines, at most 64 KiB), so a real session that
quotes prebump output later does not count as a prebump session. Every weekly sample that
does this reports `sampled_prebump_sessions` (prebump sessions in the sample) and
`skipped_prebump_sessions` (prebump sessions left out) in `local_schema`. Hermes samples one
session, so its counts are 0 or 1. A non-zero `sampled_prebump_sessions` means the store
has too few real sessions, and the union is mostly what the prebump already proved.

The union's `observed_event_count` is the sum over all sampled sessions
(`sampled_total_parsed_lines`). Before 2026-10-21 the JSONL union reported the lead
session's line count, so five 16-event sessions scored as 16 events.

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

## 5a  What to Collect as Evidence

Alongside the report fields below, record the **value-pass ruling** (§1e) for every new
key or type: handled, noise, watch, or candidate. A finding is not closed until it has
one, and candidates are not closed until they are in `docs/backlog.md`.


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
   Put verified-and-handled types in the **normal** fixture, not `schema_drift.jsonl` — see §5.
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
4. Run tests locally with the repository's stable wrapper:
   ```
   ./scripts/xcode_test_stable.sh
   ```
   Read the total from the generated XCResult and explain any decrease from the previous
   verified run; stdout contains per-bundle counts and is not the suite total.
5. For a focused discovery/parser rerun:
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
