# Format-check reference: prebump-drivers

The [runbook](../SKILL.md) governs authority and run order. Historical incidents below
explain the checks; they do not authorize sign-ins, purchases, commits or releases.

Current corrections from the 2026-11-02 run: every driver subprocess now declares a
sandbox cwd, including the OpenCode version helper and Copilot's gh-token helper.
Claude 2.1.316's fresh real-home session is still recognized as prebump by its sandbox
cwd; configured-prompt fallback continues to recognize older sessions. Environment
names/prefixes to drop are declared in prebump config and stripped in prepare_auth.
Pi now pins openai/gpt-6-luna, the provider the owner refreshed; this was a deliberate
config correction, not automatic fallback on an auth failure. The old openai-codex
credential returned refresh_token_reused/401, and both failed direct reports were kept.
Only model_unavailable permits a configured fallback model. The OpenCode DB rebuild
helper is diagnostic-only and cannot --emit: inspect its report, then add a redacted
normal fixture and survive-parsing test for DB drift explicitly.

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

   Sanity-check version identity before acting on it. If a monotonic CLI reports an
   installed version newer than `upstream.parsed_version`, or the fetched tag belongs to a
   different release family (for example an SDK release instead of the CLI), treat the
   latest source as broken/unknown. Do not follow a generated prebump recommendation for
   an agent with no driver, and do not lower a verified ceiling to match a bad source.

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
   until each new key or type has been called handled, noise, watch, or feature-candidate
   — and candidates filed in `docs/backlog.md`, not left as a remark in the ledger.

Interpretation:
- `supports_latest`: latest known build is covered by
  `evidence.fresh_evidence_source == "latest_prebump_report"` and
  `compatibility.latest_real_session_evidence == true` with
  `compatibility.latest_status == "current_fetch_known"`. This verdict is not a clean
  bill by itself: also require the **current** `weekly.schema_diff.unknown_types == []`,
  `weekly.schema_diff.unknown_keys == {}`, healthy probes, and a passing discovery
  contract. The compatibility layer can reuse an older clean prebump report while a newer
  weekly sample has already drifted; in that case report and investigate the current drift
  rather than repeating `supports_latest`.
- `supports_installed_only`: installed build is covered by non-stale real local
  evidence, but latest is newer, cached from a prior report, unknown, or lacks
  fresh real-session proof.
- `latest_unknown`: no configured/reachable latest source or no real-session
  driver exists; do not claim latest support. **Check `STEWARDS.md` before calling this
  a finding** — for a steward-verified agent not installed here, this verdict is the
  expected output and the agent belongs to its steward, not to you (§1g).
- `blocked_stale_sample`: evidence predates the installed CLI; run prebump before claiming support.
- `blocked_no_fresh_evidence`: a version changed but no fresh matching sample proves support.
- `format_drift_detected`: unknown schema/storage/usage fields appeared; update fixtures/parsers.
- `blocked_thin_sample`: the sample was both narrow and tiny, so it evidenced nothing either
  way (§5). Generate a session that actually uses tools — not a one-line prompt.
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

Keep the direct prebump `report.json` for every non-zero run and report its schema diff or
driver error from that artifact. A later weekly scan may select older clean evidence or
fall back to a stale local sample and omit the failed fresh diff; it does not erase what the
just-completed driver observed.

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

**Real-home prebump sessions do not enter the weekly sample while real sessions exist.**
A `real_home_session` prebump writes its session into the real store, where it is the
newest one. The weekly recognises these sessions and skips them, and uses them only to top
up a sample that has fewer than `_LOCAL_SCHEMA_SAMPLE_COUNT` real sessions (§5). Before
this rule, same-day prebump runs filled copilot's newest-5 union on 2026-10-21 and the
weekly reported `blocked_thin_sample` at a version its morning weekly had cleared with
122 baseline types. Still give these agents a tool-using prompt: on a machine with little
real use, the prebump sessions *are* the weekly sample. Claude's `"Say hi, then use the Bash
tool to run pwd."` is the pattern; verify any prompt change with a real run, since a
tool-using prompt can hang or return nothing on CLIs whose one-shot mode does not complete
a tool turn.

**A passing prebump is a floor, not a ceiling.** Drivers use one-line prompts, so a fresh
session may contain only the four most basic event types and still report
`fresh_matches_baseline=True` — it proves the CLI still writes parseable output, not that
rich event families are unchanged. The weekly union of real sessions is the broad evidence,
but those sessions can predate the installed build. Check the fresh session's type count
and the weekly's `sampled_prebump_sessions` before treating a pass as broad evidence.

Configured real-session drivers today are `codex`, `claude`, `antigravity`,
`copilot`, `opencode`, `hermes`, `openclaw`, `cursor`, `pi`, `kimi`, `grok`, and
`cline` (`cline_headless`, real-home: its OAuth refresh token must not be copied into
a sandbox, so run it with `--allow-real-home`). Droid is legacy-only and excluded from active checks. Qwen, Devin, and fx have no
drivers. Judge them on current weekly evidence plus their stewardship record (§1g), and
never claim latest-build support without a session written by that build. Qwen cannot
produce a newer session on this machine because its OAuth free tier was discontinued
2026-04-15; that remains blocked until a paid plan or alternate provider is configured
(see §1c).

**Staleness short-circuits the schema verdict.** `blocked_stale_sample` is reported
*instead of* drift, so a stale agent can be hiding real drift behind it. Kimi sat at
`blocked_stale_sample` while every one of its sessions carried two unmodelled event
types; building its driver surfaced them immediately. Treat a stale verdict as
"unknown", never as "clean".

Prebump uses the hybrid env-var-first auth policy: if the relevant API-key
env var (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`FACTORY_API_KEY`, `GITHUB_TOKEN`) is set it is forwarded into the sandbox
and real HOME is never read. Otherwise the driver copies the declared
credential file from real HOME into the sandbox after running three hygiene
gates (64 KiB max, mode `0600`, ≤90-day mtime warning). v1 drivers:
`codex_exec`, `claude_print`, `antigravity_print`, `copilot_prompt`,
`opencode_run`, `hermes_oneshot`, `openclaw_local_agent`,
`cursor_agent_print`, `pi_prompt`, `kimi_prompt`, and `cline_headless`. Some OAuth/keychain-backed CLIs use
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
could not replace. That historical policy is superseded for an authorized update sweep:
update first even if step 2 fails, then record a hold with the failure evidence.

**An agent with no prebump driver cannot do this loop at all.** It is permanently capped
at `supports_installed_only`, however clean its weekly looks, because nothing can produce
a session from a build on demand. Build the driver first — `grok_single` (added
2026-08-17) is the worked example, and see §1d for what building one involves.

**Re-read the installed version after the run.** Several CLIs self-update *because* the
prebump invoked them — copilot, cursor and antigravity all did on 2026-08-13 — so the
build you validated may not be the build you started with. Bump to what the post-run
report says is installed, not to what you intended to install.

---

## 1d  Building a Prebump Driver

Drivers live in `scripts/agent_watch_prebump_drivers.py` and register into `DRIVERS`;
their config block is `agents.<name>.prebump` in
`docs/agent-support/agent-watch-config.json`. Copy the nearest existing driver rather
than starting from the Protocol.

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
- **Give it a tool-using prompt.** A one-line session proves little (§1a), and for
  `real_home_session: true` agents it is also the weekly's fallback evidence on a machine
  with few real sessions (§5).
- **A `real_home_session: true` driver must leave a prebump signal in its session**, or
  the weekly cannot tell its session from a real one (§5): put an
  `AGENT_WATCH_PREBUMP_<uuid hex>` marker in the prompt, or run the CLI with its cwd in
  the sandbox (`make_sandbox()` names it `agent-watch-prebump-<agent>-…`), or give a
  SQLite store a recognisable key (OpenClaw's `:prebump-` session key). `claude_print`
  has none of these and is recognised by its configured prompt alone, so changing that
  prompt makes its older prebump sessions look real until they age out of the window.
- **If a session is a directory, verify the sidecars before returning ok.** Grok's
  `summary.json` is a discovery precondition; returning a transcript whose sidecar never
  landed hands the fingerprinter half a session and reports the gap as schema drift.

Then verify the driver the way you would verify a finding: run it, confirm
`baseline_type_count` in the report is non-zero (proving a baseline was consulted), and
confirm the fresh session actually contains a tool call rather than four trivial events.

---
