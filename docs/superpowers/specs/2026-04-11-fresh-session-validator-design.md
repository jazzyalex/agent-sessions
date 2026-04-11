# Fresh Session Validator (Hybrid Staleness + Prebump)

**Date:** 2026-04-11
**Status:** Design — open questions resolved, ready for implementation planning
**Related skill:** `agent-session-format-check`
**Scope:** Augments `scripts/agent_watch.py` weekly mode; adds a new opt-in
prebump validator. Does not change parsers, fixtures, or the matrix YAML.

---

## 1. Problem

The weekly scanner (`agent_watch.py --mode weekly`) downgrades
`installed_newer_than_verified` to `bump_verified_version` whenever
`evidence.schema_matches_baseline == true`. That evidence is computed from the
**newest on-disk session** under the agent's discovery path — but the newest
on-disk session can **predate the CLI upgrade**, so all the check proves is
that the *old* CLI's output still matches baseline. It says nothing about
whether the *new* CLI has started emitting additional event types, renamed
fields, or introduced new top-level records.

Concrete example from the 2026-04-11 weekly scan: `codex-cli` was installed
at `0.120.0`, verified at `0.119.0`, and the scanner cleared it for
`bump_verified_version`. Investigation showed the newest file under
`~/.codex/sessions/...` was from **April 6** — before the 0.120.0 upgrade.
The bump would have been premature. Copilot has an identical trap: installed
`1.0.16`, and a recent release introduced a `session.shutdown` event type that
the last sampled session on disk never exercised.

The user chose **Option C (hybrid):** keep weekly fast and on-disk, but (a)
detect and surface staleness in the evidence, and (b) add an opt-in path that
spawns a fresh headless session against the currently-installed CLI before a
bump is committed.

---

## 2. Goals / Non-goals

### Goals

- **G1.** Weekly scan flags evidence as stale whenever the newest sampled
  session predates the installed CLI binary (or a configurable freshness
  window), and severity no longer auto-downgrades to `bump_verified_version`
  in that case.
- **G2.** A new opt-in `prebump` path can spawn a real headless session per
  agent, fingerprint it with the existing schema-diff pipeline, and emit an
  exit code a commit hook or human can gate on.
- **G3.** The prebump path writes to a sandbox (fresh `HOME` / config dir)
  whenever possible, so runs do not pollute the user's real agent history.
- **G4.** Staleness detection ships for all 7 agents in v1. Prebump ships for
  the subset that already expose a reliable headless flag (see §5).

### Non-goals

- **NG1.** Fully automated unattended prebump for all 7 agents. OpenCode
  and OpenClaw need design work (sandboxing, provider credentials, channel
  routing) that is out of scope for v1.
- **NG2.** Replacing the weekly on-disk scan. We are *augmenting* it with a
  staleness flag; the on-disk fingerprint is still the first line of
  detection and stays the daily/weekly default.
- **NG3.** Running prebump from launchd/cron. It is a manual gate invoked by
  the user (or by a pre-commit hook the user installs) immediately before
  bumping `max_verified_version`.
- **NG4.** Re-litigating OpenClaw discovery or touching the version-bump yml
  files — work is already staged there.

---

## 3. Weekly-mode staleness detection (part 1 of C)

### 3.1 New evidence fields

Added to `results.<agent>.weekly` in `report.json`:

```
"local_schema": {
  ...
  "file": "<abs path to newest sampled session>",
  "mtime_utc": "2026-04-06T14:22:11Z",
  "mtime_epoch": 1712413331.0
}
```

Added to `results.<agent>.evidence`:

```
"sample_freshness": {
  "sample_mtime_utc":   "2026-04-06T14:22:11Z",
  "cli_binary_mtime_utc": "2026-04-09T08:41:02Z",
  "cli_binary_path":   "/Users/.../bin/codex",
  "freshness_window_seconds": 1209600,
  "sample_older_than_cli":       true,
  "sample_older_than_window":    false,
  "is_stale":                    true,
  "stale_reason":                "sample_older_than_cli",
  "mode_context":                "normal"
}
```

`stale_reason` describes the **cause** and is orthogonal to run mode. The
defined values are:

- `sample_older_than_cli` — signal 1 fired (sample predates the installed
  binary).
- `sample_older_than_window` — signal 2 fired (sample older than the
  freshness window).
- `cli_binary_unresolved` — `shutil.which` could not resolve the binary,
  so signal 1 is unavailable; staleness falls back to the window alone.
- `forced_fresh` — the operator passed `--force-fresh` (§4.2); staleness
  is suppressed for this run and the field records that override.
- (null) — not stale.

`mode_context` records how the scanner was invoked and is orthogonal to
the cause:

- `normal` — standard weekly run, `installed` was queried.
- `skip_update` — `--skip-update` was passed; `installed` was not
  queried but staleness detection still ran (see §3.2 interaction note).

Both fields are always present; the split means the same underlying
failure (`shutil.which` miss) reports a single consistent cause regardless
of whether `--skip-update` was in effect.

`evidence.schema_matches_baseline` stays as-is (it continues to describe
*this sample*). A new parallel field is added:

```
"evidence.fresh_evidence_available": false
```

…which is `true` only when prebump (§4) has written a fresh-session
fingerprint into the same report directory and it also matched baseline.

### 3.2 How staleness is computed

Two independent signals, OR'd together:

1. **`sample_older_than_cli`** — `sample.mtime < cli_binary.mtime`, where
   `cli_binary` is resolved by `shutil.which(agent_cfg.installed_version_cmd[0])`
   and then `os.stat`'d. This is the primary signal and covers the codex case
   directly: it pinpoints "the sampled file was written by the OLD binary".
2. **`sample_older_than_window`** — `now - sample.mtime > freshness_window`.
   The global default is **14 days**, overridable per-agent under
   `agents.<name>.weekly.freshness_window_days` in `agent-watch-config.json`.
   Cold agents the user may not exercise weekly (gemini, droid, opencode,
   openclaw) ship with a **30-day** override; the hot trio (codex, claude,
   copilot) stay at 14. This covers the "user hasn't touched this agent in a
   while and the binary was installed long ago so signal 1 is silent" edge
   case without generating noise on agents the user only runs occasionally.

**Why binary mtime** (not a recorded upgrade timestamp or package-manager
install time): every one of the 7 agents is installed via a mix of
`brew` / `npm` / `cargo` / custom installers. Under common installer
behavior the binary's inode `mtime` is refreshed when the executable is
replaced, which makes it the **best-available portable signal** that
survives all install paths without requiring a separate state file. A
recorded `~/.config/agent-sessions/agent-watch/install-timestamps.json`
was considered and rejected — it adds a new source of drift and fails
closed on first-run. Binary mtime is what everyone already uses for
`which` / `ls -l` debugging, so it is the signal least likely to surprise
an operator reading a stale-evidence report.

**Known limitations (mtime trust boundary).** Binary mtime is sound under
brew / npm / cargo / direct-download installers but is **not** a strict
lower bound on "when the user switched to this version." Documented
failure modes where the signal lies:

- **Wrapper script on PATH.** `shutil.which` resolves a shell wrapper
  whose mtime reflects the wrapper, not the underlying binary the wrapper
  execs. The mtime check reports the age of the wrapper.
- **mtime-preserving install.** `cp -p`, `install -p`, `rsync --times`,
  and some self-updaters copy the new binary with the upstream build
  time, so the inode mtime can be *older* than the local upgrade event.
- **PATH shadowing.** A stale binary earlier on `PATH` shadows a freshly
  installed one elsewhere; `shutil.which` returns the shadow and reports
  its mtime, not the real one.

Operators who hit any of these cases can use `--force-fresh` (§4.2) to
override staleness for a single run. There is no persistent override; the
next run re-evaluates from scratch.

**Why a freshness window fallback:** binary mtime alone is too lenient for
agents the user doesn't run often. If droid was upgraded 90 days ago and the
newest sample is 60 days old, signal 1 reports "fresh" — but the sample is
unlikely to exercise anything the user cares about. The 14-day window is a
defensive backstop; it can be relaxed per-agent for cold ones (e.g. droid).

If `shutil.which` cannot resolve the binary, `cli_binary_mtime_utc` is
`null`, `sample_older_than_cli` is `null`, and staleness falls back to the
freshness window alone. `stale_reason` is set to `cli_binary_unresolved`
regardless of run mode.

**Interaction with `--skip-update`.** When the weekly scanner runs with
`--skip-update`, `installed` is never queried, but staleness detection
still runs using whatever binary `shutil.which` resolves on `PATH` — the
binary mtime is cheap to stat and the user's "agents already updated
locally" assertion does not contradict it. If `shutil.which` succeeds,
`sample_older_than_cli` is computed normally; if it fails, `stale_reason`
is `cli_binary_unresolved` (same cause as the normal-mode miss). The run
mode is recorded separately in `mode_context = "skip_update"`, so the
same underlying failure never gets two different labels. The
`sample_freshness` block is never nulled out — it remains the signal
that catches the codex-style trap even when upstream checks are skipped.

### 3.3 Severity / recommendation impact

In `_pick_severity` + the post-pick override in `main()`:

- The auto-downgrade path
  (`installed_newer_than_verified && schema_matches_baseline == true →
   low / bump_verified_version`)
  becomes:
  ```
  installed_newer_than_verified
    && schema_matches_baseline == true
    && evidence.sample_freshness.is_stale == false
    → low / bump_verified_version   (unchanged)

  installed_newer_than_verified
    && schema_matches_baseline == true
    && evidence.sample_freshness.is_stale == true
    → medium / run_prebump_validator   (NEW recommendation)
  ```
- A new recommendation value `run_prebump_validator` is added to the
  severity model documented in `docs/agent-support/monitoring.md`.
  `prepare_hotfix` is still reserved for hard breakage; `run_prebump_validator`
  means "the cheap evidence is stale, run the opt-in path to confirm before
  touching the matrix."

### 3.4 Stdout one-liner

The per-agent weekly summary line gains a `stale=true|false` token with a
short reason in parentheses whenever a reason is available (stale runs,
and the `forced_fresh` override):

```
codex: severity=medium verified=0.119.0 installed=0.120.0 upstream=0.120.0
       rec=run_prebump_validator stale=true(sample_older_than_cli)

codex: severity=low verified=0.119.0 installed=0.120.0 upstream=0.120.0
       rec=bump_verified_version stale=false(forced_fresh)
```

---

## 4. Prebump validator (part 2 of C)

### 4.1 Shape: subcommand, not a new script

Added as a new `--mode prebump` to `scripts/agent_watch.py`. Reasons:

- Reuses `_jsonl_schema_fingerprint`,
  `_opencode_storage_session_tree_schema_fingerprint`,
  `_gemini_session_json_schema_fingerprint`, `_baseline_type_keys_for_agent`,
  `_schema_diff`, and `_read_verified_versions_from_matrix` with zero copy.
- Lets the prebump report land under the same
  `scripts/probe_scan_output/agent_watch/<UTC slug>/` tree so weekly and
  prebump evidence sit next to each other when referenced in the ledger.
- Avoids introducing a second CLI that drifts out of sync with the config.

A thin convenience wrapper script (`scripts/agent_watch_prebump.sh`) is
optional — not required for v1.

### 4.2 CLI surface

```
./scripts/agent_watch.py --mode prebump [--agent codex] [--agent claude] ...
                         [--keep-sandbox] [--timeout-seconds 180]
                         [--force-fresh] [--allow-real-home]
                         [--config docs/agent-support/agent-watch-config.json]
```

- `--agent` is repeatable; default is "all agents that have a
  `prebump.driver` entry in the config".
- `--force-fresh` — skip staleness evaluation for this run and treat the
  installed CLI as definitively fresh. Use when the operator knows an
  mtime-preserving install just happened or has verified freshness out of
  band (see "Known limitations" in §3.2). The run records
  `stale_reason = "forced_fresh"` in every affected `sample_freshness`
  block and the stdout one-liner (§3.4) prints
  `stale=false(forced_fresh)` so the override is visible in every
  downstream artifact. Not persistent; the next run re-evaluates.
- `--allow-real-home` — opt-in escape hatch for the copilot hermeticity
  gate (§4.4). Without this flag, a detected sandbox leak under
  `home_override` is a hard failure with exit code `4`. With it, the
  driver continues in `real_home` mode for the affected agent for this
  run only. **Use only if you understand your real config dir will be
  mutated.** Never automatic, never silent, never persistent across runs.
- Exit codes:
  - `0` — every requested agent produced a fresh session and
    `fresh_session_matches_baseline == true`.
  - `2` — at least one agent produced a fresh session whose fingerprint
    does **not** match baseline (this is the "do not bump" signal).
  - `3` — at least one agent's prebump driver failed before producing a
    session (CLI error, auth missing, timeout, no headless mode).
  - `4` — config / invariant error **or sandbox breach**. Covers unknown
    agent, missing driver, credential-copy hygiene failure (§4.4), and
    the copilot `home_override` sandbox-leak assertion when
    `--allow-real-home` was not passed.
- Intended use from a pre-commit or manual workflow:
  ```
  ./scripts/agent_watch.py --mode prebump --agent codex --agent claude \
      && git add docs/agent-support/agent-support-matrix.yml \
      && git commit -m "chore(matrix): bump codex_cli ... claude_code ..."
  ```

### 4.3 Per-agent driver registry

Drivers live in a new config section `agents.<name>.prebump`:

```json
"prebump": {
  "driver": "codex_exec",
  "sandbox": {
    "mode": "home_override",
    "subdir": "codex_sandbox"
  },
  "prompt": "Say hello and call the shell tool to run `pwd`.",
  "timeout_seconds": 180,
  "discover_session": {
    "kind": "jsonl_newest",
    "roots_relative_to_sandbox": ["$CODEX_HOME/sessions"],
    "glob": "**/rollout-*.jsonl",
    "required_types": ["session_meta"]
  }
}
```

Each driver is a small Python class in a new module
`scripts/agent_watch_prebump_drivers.py` implementing:

```python
class PrebumpDriver(Protocol):
    name: str
    def run(self, sandbox: Path, prompt: str, timeout: int) -> DriverResult: ...

@dataclass
class DriverResult:
    ok: bool
    session_path: Path | None       # newest session file the driver produced
    stdout_file: Path
    stderr_file: Path
    exit_code: int
    error: str | None               # populated when ok == False
```

The registry maps driver names (`codex_exec`, `claude_print`, `gemini_prompt`,
`droid_exec`, `copilot_prompt`, `opencode_run`, `openclaw_agent_local`) to
implementations. Adding a new agent is: implement a new subclass and add a
`prebump` block to the config.

### 4.4 Sandbox strategy

Two modes, both selected per-agent:

1. **`home_override`** (preferred): prebump creates a fresh temp directory,
   symlinks it as `$HOME` via `env -i HOME=<temp> <agent> <headless args>`,
   and also sets any agent-specific env vars
   (`CODEX_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `GEMINI_HOME`, etc.).
   The agent creates its own session tree under that HOME and never touches
   real user history. After the run, the fingerprinter is pointed at the
   sandbox root instead of `~`.

   **Auth (hybrid, env-var-first).** Each driver declares both an
   API-key env var (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
   etc.) and an optional credential-file list. At launch time the driver:
   (a) if the env var is already set in the parent environment, forwards
   it into the sandbox and does not touch real HOME at all; (b) otherwise
   copies the minimum credential files from real HOME into the sandbox
   before launching. This preserves the user's existing OAuth / ChatGPT
   session for interactive agents (the common local-dev case) while letting
   a CI or env-var-driven setup bypass credential files entirely. Copied
   credentials live only inside the temp sandbox and are removed with it;
   the duplication is brief and bounded.

   **Credential-copy hygiene checks.** Before copying any credential file
   into the sandbox the driver runs these gates, in order, and aborts with
   exit code `4` on any hard failure:

   1. **Max size.** Reject any candidate file larger than **64 KiB** per
      file. Credential files (`auth.json`, `.credentials.json`, OAuth
      token blobs) are all well under this. Oversize implies the path
      was misconfigured and is pointing at a log, a database, or a
      history file — copying it would be both a hygiene failure and a
      privacy leak. Abort with a clear error naming the offending path.
   2. **Permission check.** Require file mode `0600` or stricter (owner
      read/write only, no group, no world). If the file is group- or
      world-readable the driver refuses to copy it and tells the operator
      to `chmod 600 <path>`. This prevents the validator from silently
      handling a credential that was never meant to be machine-readable
      by anything but the owning process.
   3. **Max age warning.** If the credential file's mtime is older than
      **90 days**, log a visible `WARNING` (one line on stderr, also
      recorded in the driver's `stderr_file`) that the credential may
      have expired. This is a warning, not a failure — stale auth
      usually surfaces as an opaque CLI error later, and raising it here
      lets the operator diagnose at the right layer.

   All three gates apply per-file for every credential in the declared
   list; a single failure aborts the whole prebump run for that agent.
2. **`real_home`** (fallback): run the agent against the user's real HOME,
   then pick up the resulting session by mtime under the standard
   discovery path. Used for agents whose auth is too entangled to sandbox
   cleanly in v1 (openclaw, opencode). Pollutes real history but is honest
   about the risk.

`--keep-sandbox` preserves the temp dir for debugging; default is to delete
it on success and preserve it on failure.

### 4.5 Fingerprint + integration

After the driver returns `ok=True`:

1. The driver's `session_path` is fed into the same fingerprinter weekly
   uses (`_jsonl_schema_fingerprint` /
   `_opencode_storage_session_tree_schema_fingerprint` /
   `_gemini_session_json_schema_fingerprint`).
2. Baseline type keys are loaded via `_baseline_type_keys_for_agent` —
   same fixtures as weekly.
3. `_schema_diff` runs and a new `evidence.fresh_session_matches_baseline`
   bool is written into the prebump report alongside the existing
   `schema_matches_baseline` (which, for a prebump run, is redundant but
   kept to make the two reports structurally identical).
4. `evidence.fresh_evidence_available = true` is set.
5. The `evidence.sample_freshness` block from §3 is also populated (it is
   trivially "fresh" since the sample was just written).

The prebump report is written to
`scripts/probe_scan_output/agent_watch/<UTC slug>-prebump/report.json` and
the per-agent session file is copied (redacted? — see Open Questions) into
`scripts/probe_scan_output/agent_watch/<UTC slug>-prebump/<agent>/sample.*`.

### 4.6 How pre-commit gates on this

A documented snippet in `docs/agent-support/monitoring.md` shows the
workflow: before staging a `max_verified_version` bump for agent X, run

```
./scripts/agent_watch.py --mode prebump --agent X
```

and only commit if exit code is `0`. No hook is installed by default.

---

## 5. Per-agent headless capability matrix

All findings come from `<agent> --help` / `<subcommand> --help` on the
currently-installed binaries on this machine. Commands listed are the
minimum proposed invocation — none were executed.

| Agent      | Headless command                                             | Sandbox mode    | Auth required                    | Writes to standard discovery path? | Min prompt                                                         | v1 status           |
|------------|--------------------------------------------------------------|-----------------|----------------------------------|------------------------------------|--------------------------------------------------------------------|---------------------|
| codex      | `codex exec --sandbox read-only "<prompt>"`                  | `home_override` | ChatGPT session in `~/.codex/auth.json` | Yes (`$CODEX_HOME/sessions/**/rollout-*.jsonl`) | `List files in the current directory.` (exercises session_meta, token_count, tool_call) | **v1**              |
| claude     | `claude -p --output-format stream-json --session-id <uuid> "<prompt>"` | `home_override` | `~/.claude/.credentials.json` or `ANTHROPIC_API_KEY` | Yes (`~/.claude/projects/**/*.jsonl`) — `--print` still writes the session unless `--no-session-persistence` is passed, and we specifically *want* persistence | `Say hi, then use the Bash tool to run pwd.` (exercises user, assistant, tool_use, tool_result) | **v1**              |
| gemini     | `gemini -p "<prompt>" --output-format json --yolo`           | `home_override` | `~/.gemini/**` OAuth or `GEMINI_API_KEY` | Yes (`~/.gemini/tmp/<hash>/chats/session-*.json`) | `Say hello and list files.`                                        | **v1**              |
| droid      | `droid exec --auto low "<prompt>"`                           | `home_override` | `~/.factory/**` token              | Yes (`~/.factory/sessions/**/*.jsonl`) | `Briefly describe this directory.` (exercises message events + tool call) | **v1**              |
| copilot    | `copilot -p "<prompt>" --allow-all-tools`                    | `home_override` | `~/.copilot/**` gh auth            | Yes (`~/.copilot/session-state/<uuid>/events.jsonl`) | `Run ls.` (needed to trigger tool events + `session.shutdown`)    | **v1** (target the codex/copilot trap directly) |
| opencode   | `opencode run --format json "<prompt>"`                       | `real_home` initially; `home_override` is possible via `XDG_DATA_HOME`/`XDG_CONFIG_HOME` but needs validation | `~/.local/share/opencode/**` provider creds | Yes (`~/.local/share/opencode/storage/session/**/ses_*.json`) | `Say hello.`                                                       | **v2** (need to confirm sandbox + provider cred handling before shipping) |
| openclaw   | `openclaw agent --local --message "<prompt>" --session-id <uuid> --json` | `real_home` (gateway/profile routing is stateful) | Model provider API keys in shell + channel config | Yes (`agents/<id>/sessions/*.jsonl` per discovery contract) — but `--local` bypasses the gateway and may write to a different path | `hello`                                                            | **v2** (verify local mode actually creates a standard session file; the `--profile dev` + `--dev` flags suggest a cleaner sandbox option exists) |

### Notes collected during investigation

- **codex.** `codex exec` is the documented non-interactive entry
  (`codex exec --help` lists `PROMPT` as an optional positional; stdin also
  accepted). `-c` overrides let the driver pin the model to something cheap
  if needed. Writes to `$CODEX_HOME` which respects env override; ideal for
  sandboxing.
- **claude.** `claude -p "<prompt>"` is print mode. `--session-id <uuid>`
  forces a known path under `~/.claude/projects/<cwd-hash>/<uuid>.jsonl` —
  removes the "where did the new session land" race. `--bare` mode could
  further de-risk side effects but disables auto-memory which we may want
  on for realism.
- **gemini.** `-p` is the documented headless flag. `--yolo` auto-approves
  tools so the run completes without a TTY. `-o stream-json` could be used
  to validate the stream as it arrives, but fingerprinting the persisted
  `session-*.json` matches what weekly already parses.
- **droid.** `droid exec` is the documented non-interactive entry.
  `--auto low` / `--skip-permissions-unsafe` sidestep prompts. `--cwd`
  lets the driver control where the session is rooted.
- **copilot.** `-p "<prompt>"` is the documented non-interactive mode;
  `--allow-all-tools` (or `COPILOT_ALLOW_ALL=1`) is required.
  `--config-dir` overrides `~/.copilot` directly, which makes sandboxing
  trivial — this is why copilot is v1 despite being the motivating trap.
  **Implementation gate (fail-closed, no auto-downgrade).** Every copilot
  driver invocation runs a sandbox-leak assertion: before launch it marks
  a start timestamp, and after the run it stats every file under real
  `~/.copilot` with `find ~/.copilot -newer <marker>`. If any file in
  real HOME was modified during the run the driver **hard-fails with
  exit code 4** (sandbox breach) and emits a loud diagnostic naming the
  polluted paths. There is no silent downgrade. An operator who has read
  the diagnostic and accepts the consequences can rerun with the
  explicit `--allow-real-home` flag (§4.2), which allows the affected
  run to continue against real HOME for that invocation only. The
  override is never automatic, never silent, and never persistent across
  runs — the next prebump run re-asserts hermeticity from scratch.
- **opencode.** `opencode run "<message>" --format json` exists. Storage is
  a multi-file tree under `~/.local/share/opencode/storage/`; the tree root
  can in theory be relocated via `XDG_DATA_HOME`, but we have not
  confirmed that opencode honors `XDG_DATA_HOME` in v1.4.3. The OpenCode
  baseline fingerprinter already handles the tree, so once sandboxing is
  sorted this becomes a small change. Deferring to v2.
- **openclaw.** `openclaw agent --local --message "..."` runs an embedded
  turn without the gateway, but it still needs at least one model provider
  API key in the shell env, and the "session id" semantics are tied to
  the channel-routing system. The existing `--profile dev` + `--dev` flags
  already give us an isolated state dir; that is the most promising
  sandbox path, but requires enough investigation to be out of v1 scope.

---

## 6. Staged rollout

### v1 (ships with this design)

- **All 7 agents** get staleness detection (§3). This is the main bug fix
  and can land independently of any prebump work.
- **Prebump drivers for 5 agents:** codex, claude, gemini, droid, copilot.
  These all have a first-class `-p`/`exec` flag and either
  config-dir/env-var sandboxing (codex, copilot, gemini) or
  HOME-override sandboxing (claude, droid).
- New `--mode prebump` subcommand wired into `agent_watch.py` with the
  driver registry skeleton.
- `docs/agent-support/monitoring.md` gets a new section documenting the
  prebump workflow, exit codes, and recommended pre-commit snippet.
- `run_prebump_validator` added to the severity/recommendation vocabulary.

### v2 (follow-up)

- **opencode** prebump driver. Requires confirming that `XDG_DATA_HOME` /
  `XDG_CONFIG_HOME` overrides are honored by opencode v1.4.3+, and wiring
  provider credential propagation.
- **openclaw** prebump driver. Requires understanding
  `openclaw --profile <name>` + `--dev` isolation well enough to guarantee
  the session lands in the discovery path the weekly scanner already
  watches, and deciding which channel/config the embedded agent should
  use.
- Optional: machine-readable pre-commit hook script in
  `scripts/hooks/pre-commit-matrix-bump.sh`.
- Optional: integrate `fresh_session_matches_baseline` into the auto-bump
  recommendation rule, so with a fresh-evidence run present the weekly
  scan can once again recommend `bump_verified_version` without a manual
  step.

---

## 7. Resolved design decisions

1. **Freshness window default — resolved.** Global default 14 days, with a
   per-agent 30-day override for cold agents (gemini, droid, opencode,
   openclaw) in `agent-watch-config.json`. Rationale: the hot trio is where
   stale samples produce false "safe to bump" calls weekly, while cold
   agents need slack so the backstop does not fire every scan on a dormant
   installation. See §3.2.
2. **Prebump prompt depth — resolved.** v1 ships a single minimum
   single-tool-call prompt per agent (as listed in §5); a `--deep` flag is
   explicitly deferred to v2 as an additive, per-agent usage/rate_limits
   probe. Rationale: the motivating bug is schema-family drift
   (`session.shutdown`, new event types), which the minimum prompt already
   exercises; adding a deep probe now spends real tokens per run and
   couples v1 shipping to quota decisions we do not need to make yet.
3. **Fresh-session redaction — resolved.** Prebump writes raw sessions into
   the gitignored `scripts/probe_scan_output/agent_watch/<slug>-prebump/`
   tree; no redaction pass in v1. Rationale: prompts are scripted and
   contain no user data, the output path is gitignored, and redaction
   would complicate schema-diff comparisons against baseline fixtures
   for no privacy win.
4. **Auth material in sandboxed HOME — resolved.** Hybrid, env-var-first:
   if an agent's API-key env var is already set in the parent environment
   the driver forwards it and never touches real HOME; otherwise the
   driver copies the minimum credential files from real HOME into the
   temp sandbox, which is torn down on exit. Every copied file passes
   three hygiene gates before the copy: max size 64 KiB (reject larger,
   exit 4), mode `0600` or stricter (reject world/group readable, exit
   4), and a visible WARNING if mtime is older than 90 days (non-fatal).
   Rationale: least surprise for a local developer who already has a
   working OAuth / ChatGPT session, plus a clean escape hatch for anyone
   running with API keys, plus explicit guardrails so a misconfigured
   credential list cannot smuggle a log or history file into the
   sandbox. See §4.4.
5. **Copilot `--config-dir` hermeticity — resolved (fail-closed runtime
   gate).** We ship copilot as v1 under `home_override`, and every
   copilot driver invocation runs a sandbox-leak assertion. If any file
   under real `~/.copilot` is modified during the run the driver
   hard-fails with exit code `4` (sandbox breach) and emits a loud
   diagnostic. There is **no automatic, silent, or persistent downgrade
   to `real_home`**. An operator who reads the diagnostic and accepts
   the consequences can rerun with the explicit `--allow-real-home`
   flag, which permits `real_home` mode for that invocation only. The
   next run re-asserts hermeticity from scratch. Rationale: we were
   told not to run the CLI during design, so the design cannot prove
   `--config-dir` is hermetic; a fail-closed runtime check is the
   correct place to verify it, and forcing an explicit opt-in per run
   keeps the "my real config dir might be mutated" decision in the
   operator's hands every time. See §5 copilot note and §4.2.
6. **`--skip-update` interaction — resolved.** Staleness detection keeps
   running under `--skip-update`. `sample_older_than_cli` is computed from
   whatever `shutil.which` resolves (cheap, local). `stale_reason`
   carries the **cause** (`cli_binary_unresolved` when `which` fails)
   and `mode_context` separately carries the **mode**
   (`skip_update`), so the same underlying failure never gets two
   different labels. `sample_freshness` is never nulled out. Rationale:
   the whole point of the freshness signal is to catch the codex trap
   even when the user *thinks* they are up to date, which is exactly
   the scenario `--skip-update` is asserting. See §3.1 and §3.2.
7. **Binary mtime trust boundary — resolved.** Binary mtime is the
   best-available portable signal, sound under brew / npm / cargo /
   direct-download installers, but it is not a strict lower bound on
   "when the user switched to this version." Documented failure modes
   (wrapper scripts on PATH, mtime-preserving installs via `cp -p` /
   `install -p` / `rsync --times`, PATH shadowing) are enumerated in
   §3.2 "Known limitations." Operators who hit one of these can pass
   `--force-fresh` (§4.2) to override staleness for a single run; the
   override records `stale_reason = "forced_fresh"` in the report and
   the stdout one-liner, and does not persist. Rationale: keep the
   trust model honest about what the signal actually proves, and
   surface a per-run escape hatch rather than a persistent opt-out.
