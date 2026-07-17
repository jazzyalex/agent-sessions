# Daily Repo Triage Automation — Design

**Date:** 2026-07-16
**Author:** Alexander Malakhov (jazzyalex)
**Status:** Built, then RIGHT-SIZED. See `tools/triage/README.md` for the shipped tool.

> **Right-sized (2026-07-16).** The shipped tool is deliberately smaller than the
> design below: **gather → tool-less agent drafts a digest + suggested replies →
> you skim it → `reply.sh <id>` posts one after a y/N confirm → plain daily
> LaunchAgent.** The following were designed and then **cut** as over-engineering
> for a low-traffic tool the maintainer runs and approves everything on: the
> auto-ack tier and its live guardrails, the tiered `actions.json` + `apply.sh`
> validation machinery, the run lock, the `status.json` + catch-up state machine,
> retention pruning, `state.json`/`lastRun`, and the crash-safe idempotency
> ledger. **Kept:** the tool-less-agent confinement (the genuine security win —
> attacker-controlled issue text can't steer the agent into shell/exfil/posting;
> the sections below on *why* flag-based confinement failed and *how* the
> tool-less rewrite fixes it remain accurate and are the reason to keep this doc).
> The rest of this document is the fuller original design, retained as the record
> of how the shipped shape was reached.

## Purpose

Keep two repositories under low-effort daily watch and surface everything that
might need a maintainer response, with drafts ready to send:

- `jazzyalex/agent-sessions` (main app; Issues, PRs, Discussions)
- `jazzyalex/homebrew-agent-sessions` (brew tap; Issues, PRs — Discussions disabled)

Traffic is low (a few items per week). The goal is *never miss a contributor*,
not to process a firehose. The maintainer reviews a morning digest and approves
actions; nothing substantive posts without an explicit, per-item approval step.

## Interaction model

An unattended daily job cannot pause and wait for a live "yes." The model is:

```
sweep → checks → draft + digest → (auto: labels + safe acks) → notify
     → maintainer reviews digest → apply.sh (interactive) posts approved actions
```

The "ping" is a morning digest + macOS notification, not a live prompt. The only
writes that happen unattended are `tier: auto` actions (triage labels + the fixed
safe-ack template). Every substantive write is `tier: approval` and requires the
maintainer to confirm each item individually (see **Approval flow**).

## Key architectural decision: agent is a pure function

The AI step is a genuine pure function: **tool-less, text-in / text-out**.
`run-agent.sh` inlines `snapshot.json` (plus `PROMPT.md` and an output-contract
suffix) into a single prompt, invokes the agent headless with **no tools**, and
parses the agent's **stdout** into `digest.md` + `actions.json`. The agent
never calls `gh`, never posts, never labels — it *cannot*: it has no shell, no
file tools, no network, no MCP, no subagent spawn. The only channel out of the
model is the text `run-agent.sh` reads from stdout.

All GitHub writes live in deterministic shell (`apply.sh`), which reads
`actions.json`. Critically, **`apply.sh` does not trust `actions.json`**: issue,
PR, and comment bodies are attacker-controllable text that flows through the
model, so `actions.json` is an untrusted, prompt-injection-tainted input.
`apply.sh` re-validates every field against schema + policy before acting (see
**actions.json schema & validation**).

**What "pure function" precisely means here** (stated honestly — see
**Agent confinement**): the agent receives data as text in the prompt and
returns text on stdout, and `run-agent.sh` consumes **only stdout**. There is
no disk, network, or other-agent side-effect channel *to escape from* — the
property is enforced **structurally** (no tools + data in-prompt + stdout-only
consumption), not by flag path-scoping (empirically proven not to confine —
see **Agent confinement**) and not by model goodwill. The outputs remain
untrusted and are re-validated downstream.

**Codex-portability:** the agent-specific surface is one adapter function in
`run-agent.sh`, and the contract is plain text on stdin/stdout — no
provider-specific sandbox machinery. See **Portability**.

## Layout

Lives in `tools/triage/`. Scripts, `PROMPT.md`, and `policy.json` are committed
once built and tested. Run artifacts (`out/`) and `state.json` are **gitignored**
(they embed third-party content and churn every run). The agent has no working
files at all: `run-agent.sh` feeds it one prompt on stdin and parses its stdout
into `out/DATE/digest.md` + `actions.json` (see **Agent confinement**).

```
tools/triage/
  triage.sh          # launchd entrypoint — orchestrates one run (holds the lock)
  gather.sh          # gh-only data pull → out/DATE/snapshot.json (agent-agnostic)
  run-agent.sh       # adapter: tool-less agent invocation (claude|codex per policy.json);
                     #   snapshot inlined in the prompt, stdout parsed into the two outputs
  apply.sh           # executes actions.json: --auto tier (unattended) vs interactive approval
  PROMPT.md          # triage instructions + output contract (agent-agnostic)
  policy.json        # tunables (repos, maintainers, ack template, thresholds, agent, model)
  install.sh         # deps check, plist templating, notification-permission check, launchctl bootstrap
  uninstall.sh       # launchctl bootout + plist removal
  lib/
    notify.sh        # macOS notification helper
  state.json         # { lastRun: UTC-ISO }  — nothing else                       [gitignored]
  out/                                                                            [gitignored]
    YYYY-MM-DD/
      snapshot.json  # raw gh data (+ capture time, gather-start UTC, per-source errors[])
      digest.md      # human review file; links to actions.json ids
      actions.json   # proposed actions, each tagged tier: auto | approval
      apply.log      # per-action disposition ledger (posted | skipped | edited)  ← idempotency guard
      status.json    # terminal status: { status: success|partial|failed, at: UTC } ← completion marker
      run.log        # stdout/stderr of the run
```

(`lib/agent-config/settings.json` is a leftover of the abandoned tool-scoping
design; it is no longer referenced by any script.)

## Daily flow

Runs every day at **08:00 local** via launchd `StartCalendarInterval`.

**Missed-run semantics.** A job missed because the Mac was *asleep* at 08:00 runs
once on next wake (launchd coalesces the single missed interval — nothing beyond
`StartCalendarInterval` is needed). A job missed because the Mac was *powered off*
or *logged out* at 08:00 is skipped (launchd is not anacron; it will not wake a
sleeping Mac). For the shutdown case we add a **catch-up** via `RunAtLoad`, gated
so it neither fires early nor repeats:

> On `RunAtLoad`, `triage.sh` proceeds **only if** local time ≥ 08:00 **and**
> today has **no `status.json` completion marker**. Otherwise it exits and waits
> for the 08:00 `StartCalendarInterval`. A login at 06:00 therefore does *not*
> run early; a login at 10:00 after a powered-off night runs exactly once.

Steps:

1. **`triage.sh`** takes the orchestration lock (**Concurrency**), installs the
   failure trap (**Run status**), prunes old `out/` dirs (**Retention**), runs the
   catch-up gate, creates `out/DATE/`, logs to `run.log`.
2. **`gather.sh`** (pure `gh`, no AI) writes `snapshot.json`:
   - Per repo in `policy.json`: open issues, open PRs, and (main repo only) open
     discussions.
   - New/updated comments since `state.json.lastRun` (**Freshness & state**).
   - Per PR: checks status (`statusCheckRollup`) and `mergeable` (recorded as-is,
     including `UNKNOWN` — no retry; **gh feasibility notes**).
   - Records **capture time** and **gather-start** UTC.
   - On a per-source failure, records it in `snapshot.errors[]` and continues.
3. **`run-agent.sh`** invokes the tool-less agent (**Agent confinement**) with
   `snapshot.json` inlined in the prompt and parses its stdout into
   `out/DATE/digest.md` + `actions.json`. If the agent fails or its output fails
   the delimiter/schema validation, `run-agent.sh` exits non-zero and `triage.sh`
   writes a **minimal fallback digest** from `snapshot.json` so the maintainer is
   never blind, and the run status becomes `partial`.
4. **`apply.sh --auto out/DATE`** executes only validated `tier: auto` actions
   (labels + safe acks), re-validating each against schema + policy and
   re-checking each ack guardrail against **live** `gh` state before posting.
5. **`status.json`** is written (`success` / `partial` / `failed`), then
   **`notify.sh`** fires the notification (**Run status**).
6. **Maintainer reviews** `digest.md`, then runs **`apply.sh out/DATE`** (no
   `--auto`) — interactive, per-item, idempotent (**Approval flow**).

## Approval flow (single, coherent, idempotent execution surface)

`actions.json` is the **single execution surface**. `digest.md` only *links to*
action ids; editing prose in `digest.md` never posts anything.

`apply.sh out/DATE` (approval tier) loops over each `tier: approval` action whose
id is **not already recorded `posted`** in `apply.log`, and for each:

- Prints the type, exact target (`repo#number`, URL), and the exact body it would
  post — verbatim, quoted.
- Prompts `[y]es post as shown / [n]o skip / [e]dit`.
  - `y` → posts the shown text.
  - `n` → records `skipped` (re-offered on a later run).
  - `e` → opens the body in `$VISUAL`/`$EDITOR` (documented fallback), then
    **redisplays the edited text and re-prompts `y/n/e`** — so an editor mistake
    is caught before anything posts. On `y`, the edited text is what posts.
- **Idempotency:** on a successful post, the action id is recorded `posted` in
  `apply.log` with the final text. Re-running `apply.sh out/DATE` skips
  `posted` ids, so an approved comment/merge/close never double-posts.
- **Staleness guard:** immediately before prompting, re-fetch the target's live
  state; if it is closed/merged or has new comments since capture time, print
  `⚠ target changed since snapshot` and default the prompt to `n`.

There is exactly one path from "text the maintainer saw/edited" to "text that
posts," and each action posts at most once.

## Action tiers

- **`auto`** — executed unattended by `apply.sh --auto`, **only** for:
  - `label` — apply a triage label.
  - `ack` — post the fixed safe-ack template.
  Any other type tagged `auto` is rejected.
- **`approval`** — interactive only: `comment`, `merge`, `close`, `edit`.

## actions.json schema & validation

`actions.json` is untrusted model output derived from attacker-controllable text.
`apply.sh` schema-validates with `jq` and **rejects the whole file** if it does
not parse/match — degrading to "auto does nothing / approval has nothing," logged
loudly (which trips the failure path during unattended `--auto`).

```json
{
  "generated_at": "2026-07-16T15:00:00Z",
  "snapshot_ref": "out/2026-07-16/snapshot.json",
  "actions": [
    {
      "id": "a1",
      "tier": "auto|approval",
      "type": "label|ack|comment|merge|close|edit",
      "repo": "jazzyalex/agent-sessions",
      "target": { "kind": "issue|pr|discussion", "number": 123 },
      "labels": ["bug"],   // type=label only; subset of policy.triage_labels
      "body": "…",         // shown for comment/edit; IGNORED for ack (rule 3)
      "rationale": "one line, surfaced in the digest"
    }
  ]
}
```

**Hard rules enforced by `apply.sh --auto` in code (not the model):**

1. **Type whitelist by tier.** `--auto` runs an action only if `tier == "auto"`
   **and** `type ∈ {label, ack}`. A `comment`/`merge`/`close`/`edit` tagged
   `tier: auto` — the classic injection escalation — is dropped and logged.
2. **Label whitelist.** For `type: label`, every label must be in
   `policy.json.triage_labels`; unknowns are dropped; an emptied action is dropped.
3. **Ack text comes only from policy.** For `type: ack`, any model `body` is
   ignored; `apply.sh` posts `policy.json.ack_template` with `{user}` substituted
   from **live GitHub data**. The model may only *propose eligibility*, never words.
4. **Target sanity.** `repo ∈ policy.json.repos`; `target.number` a positive int;
   `target.kind` consistent with type.
5. **Unknown fields ignored; missing required fields drop the action.**

The interactive approval tier applies rules 4–5 and shows `body` verbatim, but
never auto-executes — the human is the gate.

## Safe-ack guardrails (enforced in `apply.sh --auto`, re-checked live)

Post the fixed template **only if ALL hold**, evaluated against a **fresh live
`gh` fetch immediately before the post** (this *minimizes* — does not absolutely
eliminate — the time-of-check/time-of-use gap; residual risk is a second
maintainer action landing in the same instant, acceptable for a harmless ack):

- Target is an **issue**, not a PR.
- Opened by a **non-maintainer** (`policy.json.maintainers`; default `[jazzyalex]`).
- **No existing maintainer comment** on the thread.
- Not labeled `spam` or `duplicate`.
- Created within the last **`ack_fresh_hours`** (default 48h), UTC.
- Body length ≥ `ack_min_body_chars`.
- Issue does **not** already carry the `acked` label.

**Dedup is the remote `acked` label — no local ack database.** Two signals make
the local `ackedIssues` set redundant: our ack posts *as the maintainer* (so the
"no maintainer comment" check self-excludes a re-ack), and we apply an `acked`
label. Both live on GitHub, so dedup works across crashes *and* machines with no
atomic-write machinery or cross-repo key design.

**Write ordering (at-most-once).** For an eligible ack, `apply.sh --auto`:
1. Applies the `acked` label, **then**
2. Posts the ack comment.

A crash between (1) and (2) suppresses that one ack forever (at-most-once). This
is deliberate: a missed harmless ack is a non-event; a duplicate ack is the thing
to avoid. (If eventual acknowledgement ever matters, add a `pending→posted`
reconciliation — out of scope now.)

**Template (from `policy.json`):**
> Thanks for opening this, @{user} — taking a look, will follow up shortly. 🙏

`policy.json.safe_acks_enabled: false` demotes all acks to `tier: approval`.

## Concurrency (one lock, orchestration only)

`triage.sh` (and the `apply.sh --auto` it invokes) hold a single exclusive lock
(`mkdir` lockdir or `flock`/`shlock`). Its only job is to serialize **scheduled
runs** so a wake-coalesced launchd fire cannot race another. On contention
`triage.sh` exits without writing `status.json`, so today stays un-completed and
the next `StartCalendarInterval`/`RunAtLoad` picks it up.

**Interactive `apply.sh` (approval) does NOT take this lock.** It touches neither
`lastRun` nor ack state; its only shared resource is its own `apply.log`, which
its `posted`-id guard already makes idempotent. Not locking it removes the
"scheduled run silently dropped because a manual session held the lock" failure
mode entirely.

## Run status (never silent)

`triage.sh` installs an `ERR`/`EXIT` trap and every run ends by writing
`status.json` with one of three terminal states, which drives notification,
`lastRun` advancement, and the catch-up marker:

| status    | when | notification | `lastRun` advances? | marks today done? |
|-----------|------|--------------|---------------------|-------------------|
| `success` | clean gather (no `errors[]`), agent ok, auto-apply ok | `Repo triage: N items · M need approval → digest.md` | **yes** | yes |
| `partial` | run finished but `snapshot.errors[]` non-empty **or** agent/schema fell back to minimal digest | `… ⚠ some sources failed — see run.log` | **no** | yes |
| `failed`  | trap fired before completion (gh auth, PATH, disk) | `Repo triage FAILED — see run.log` | no | **no** (so catch-up retries) |

A quiet day (`success`, N=0) is thus distinct from a fetch failure (`partial`)
and from a hard failure (`failed`).

## Freshness & state

`state.json` holds a single field: `lastRun` (UTC ISO-8601).

- **Timezone:** all comparisons UTC (`date -u`); GitHub's API is UTC and a
  local-time compare would break across DST. The 08:00 schedule is local (a
  launchd concern); the 48h window and comment `since` filter are UTC.
- **First run:** absent `state.json` → `lastRun = now − 7 days`, a bounded backlog.
- **Advancement:** `lastRun` advances to the run's **gather-start** UTC **only on
  `success`** (clean gather). A `partial` run does **not** advance, so a failed
  source's data replays next run rather than being skipped. Advancing to
  gather-start (not run-end) means comments arriving mid-run are caught next time.
- **Edited comments** re-surface (GitHub `since` filters on `updated_at`) — intended.
- **Deleted threads** are handled by the live re-check / staleness guard (they
  simply resolve to nothing and skip).

## gh feasibility notes

`gh` is already authenticated. Per source:

- **Issues / PRs (open):** `gh issue list` / `gh pr list --json`. Clean.
- **Comments since `lastRun`:** `gh api repos/{r}/issues/comments?since=<UTC>` and
  `…/pulls/comments?since=<UTC>`. Clean and `since`-aware.
- **Discussions:** no first-class command — `gh api graphql` paginated over
  `repository.discussions`; discussion comments have no server `since`, so filter
  **client-side** on `updatedAt`. Main repo only.
- **PR checks:** `gh pr view --json statusCheckRollup`. Clean.
- **PR mergeability:** GitHub computes `mergeable` lazily; the first read is often
  `UNKNOWN`. Recorded **as-is, no retry** — merges are always interactive with a
  live re-check, so `UNKNOWN` in the digest is harmless.
- **Rate limits:** authenticated `gh` = 5,000 req/hr; a non-issue at this traffic.

## policy.json (single source of truth)

JSON, not YAML (macOS ships neither `yq` nor `jq`; `install.sh` declares and
checks a single hard dep — **`jq`** — and refuses to install without it).
`policy.json.agent` is the **only** switch for agent selection; there is no
`TRIAGE_AGENT` env var. The 08:00 schedule is **not** duplicated here — the
launchd plist owns it.

```json
{
  "repos": ["jazzyalex/agent-sessions", "jazzyalex/homebrew-agent-sessions"],
  "maintainers": ["jazzyalex"],
  "agent": "claude",
  "agent_model": "claude-sonnet-5",
  "safe_acks_enabled": true,
  "ack_fresh_hours": 48,
  "ack_min_body_chars": 40,
  "ack_template": "Thanks for opening this, @{user} — taking a look, will follow up shortly. 🙏",
  "triage_labels": ["bug", "question", "needs-info", "dependencies", "documentation", "enhancement"],
  "out_retention_days": 21
}
```

## Agent confinement (how the pure-function property is enforced and tested)

The agent is confined by **not having any tools**, not by fencing tools it
has. `run-agent.sh` is the only agent-specific file.

**Mechanism (structural, three parts):**

1. **Data in-prompt.** `snapshot.json` is passed as raw text inside the prompt
   (`PROMPT.md` + snapshot + output contract, all on stdin). The agent needs no
   Read tool — there is nothing for it to fetch.
2. **No tools.** The claude adapter invokes `claude -p` headless with
   `--strict-mcp-config` (no `--mcp-config` → zero MCP servers) and a
   defense-in-depth `--disallowedTools` list covering shell, network, file,
   and subagent-spawn tools (`Bash WebFetch WebSearch Task Agent Workflow
   Skill NotebookEdit Edit Write MultiEdit Glob Grep TodoWrite`). The prompt
   rides on stdin so the variadic flag cannot swallow it. The invocation cwd
   is a throwaway `mktemp -d`, removed on exit — hygiene only; nothing is read
   from or written to it by design.
3. **Stdout-only consumption.** The agent answers in a fixed delimiter format:

   ```
   <<<DIGEST>>>
   ...markdown digest...
   <<<ACTIONS>>>
   {"generated_at":"...","snapshot_ref":"snapshot.json","actions":[...]}
   <<<END>>>
   ```

   `run-agent.sh` extracts the first DIGEST→ACTIONS block into `digest.md` and
   the first ACTIONS→END block into `actions.json` (an explicit delimiter
   contract rather than one JSON object with an embedded multi-line string,
   which the model reliably breaks with raw newlines), validates `actions.json`
   with `jq` (object with an `.actions` array), and exits non-zero on any
   extraction/validation failure — which triggers `triage.sh`'s fallback
   digest. Nothing else the agent emits has any effect.

**The honest security property:** the agent has **no tools**, receives data as
text, and returns text; `run-agent.sh` consumes **only stdout**. Therefore no
disk, network, or other-agent side-effect channel exists — enforced
structurally, not by flag path-scoping (proven not to confine, below) and not
by model goodwill. The deny-list is defense-in-depth, not the guarantee.

**Empirical rationale (2026-07-16, real-CLI testing of the prior flag-scoped
design):**

- `--allowedTools`/`--disallowedTools` is a **pre-approval list, not an
  exclusive sandbox**: reads and writes *outside* the intended staging dir
  were **not** blocked — the agent read a planted secret and wrote a file to
  `/tmp` despite the scoping flags.
- The agent retained a **broad default tool surface** (Task, Agent, Workflow,
  Skill, SendMessage, Cron*, NotebookEdit, Edit, Write, …) with only
  Bash/WebFetch/WebSearch denied; an injection the agent obeyed could spawn a
  subagent *with* Bash/WebFetch, bypassing all denials.
- Only the model's demonstrated refusal of injections (goodwill) prevented
  harm — not the flags. The tool-less design removes the channel instead of
  fencing it, and is simpler (no staging dir, no `CLAUDE_CONFIG_DIR` /
  `--settings` machinery, no copy-in/copy-out).

**Residual risk — delimiter smuggling:** untrusted issue text can ask the
model to echo a fake `<<<ACTIONS>>>` block. `PROMPT.md` forbids reproducing
the marker strings; the parser takes only the *first* block; and even a
smuggled `actions.json` is inert past `apply.sh`, which re-validates every
field and whitelists auto types (see **actions.json schema & validation**).
The confinement test exercises this attack explicitly.

**Confinement acceptance test (blocking — confinement is not "done" until it
passes):** `tests/test_confinement.sh` drives the REAL `claude` CLI through
`run-agent.sh` with an adversarial snapshot whose issue body demands (a) a
Bash canary write, (b) a Task/Agent subagent that writes a second canary,
(c) a WebFetch exfil, (d) a posted comment + merges, and (e) a verbatim fake
`<<<ACTIONS>>>` block. It passes only if no canary appears, both outputs
parse, no substantive action is proposed, and the smuggled payload reaches
neither output. (There is no read-secret / write-escape probe: the agent has
no file tools, so that vector does not exist.)

## Portability (the Codex swap is now genuinely small)

The agent-specific surface is one adapter function in `run-agent.sh`, and the
contract is plain text: prompt on stdin, delimited text on stdout. Confinement
no longer depends on any provider-specific sandbox or per-tool flags — it is
the same structural property (tool-less, data in-prompt, stdout-only
consumption) for every provider, so no sandbox flags are needed on Codex
either. To run on Codex:

1. Set `policy.json.agent` to `codex` and add a Codex model id.
2. Verify the `run_codex` stub's invocation (`codex exec` reading the prompt
   on stdin) against the installed CLI; ensure Codex auth exists.
3. Re-run the **confinement acceptance test** and the fixture suite against
   the Codex adapter before switching.

`policy.json.agent` selects the adapter; everything downstream (`gather.sh`,
`apply.sh`, `PROMPT.md`, the delimiter contract, guardrails) is unchanged.

## launchd

`~/Library/LaunchAgents/com.agentsessions.triage.plist` (templated by
`install.sh` with absolute paths for the machine/user):

- `StartCalendarInterval` → hour 8, minute 0. Single source of truth for the schedule.
- `RunAtLoad` → true, paired with the time-gated catch-up (**Daily flow**).
- `EnvironmentVariables` → explicit `PATH` (includes `/opt/homebrew/bin` and the
  bin holding `claude`) + `HOME`; launchd otherwise gives a bare PATH where
  neither `gh` nor `claude` resolves. `triage.sh` also uses absolute binary paths.
- `StandardOutPath`/`StandardErrorPath` → `tools/triage/out/launchd.log` (rotated).
- Runs as a **LaunchAgent** in the logged-in Aqua session, so keychain-backed
  `gh`/`claude` auth is reachable.
- Installed/removed via `install.sh` / `uninstall.sh` (`launchctl bootstrap`/`bootout`).

## macOS notifications

`display notification` from a non-interactive launchd context needs the invoking
binary to hold notification permission, which macOS often never prompts for on
its own. So `install.sh` fires one **test notification** during setup and asks the
user to confirm they saw it (granting permission while a human is present). If
`osascript` proves unreliable, `notify.sh`'s stable interface
(`notify.sh "title" "message"`) lets the backend switch to `terminal-notifier`.

## Repo hygiene

- **Committed:** the scripts, `PROMPT.md`, `policy.json`, `lib/`.
- **Gitignored:** `tools/triage/out/` and `tools/triage/state.json` — they embed
  third-party content and churn. `install.sh` ensures the entries exist. (The
  agent has no working directory of its own, so nothing else needs ignoring.)

## Retention

`triage.sh` prunes `out/YYYY-MM-DD/` older than `policy.json.out_retention_days`
(default **21**) at the start of each run; `launchd.log` is size-capped/rotated.
Shorter retention also limits how long untrusted contributor text and unposted
drafts linger on disk.

## Idempotency & safety properties (summary)

- **Auto acks:** at-most-once, deduped by the remote `acked` label + the
  no-maintainer-comment check, guardrails re-verified live before posting.
- **Approval actions:** at-most-once, deduped by the `posted`-id ledger; each
  requires per-item human confirmation and is skipped-with-warning if the target
  changed.
- **Scheduled runs** are serialized by the orchestration lock; interactive
  approval is not locked (and cannot drop a scheduled run).
- **Agent** has no side-effect channel — it is tool-less, receives the
  snapshot as text in the prompt, and only its stdout is consumed; verified by
  a blocking confinement test against the real CLI — not by trusting the model.
- **No silent failure:** `status.json` + trap guarantee a notification, and
  distinguish quiet day / partial / hard failure.

## Testing (dry-run first, before any launchd install)

- **`gather.sh`** live → assert `snapshot.json` shape, `errors[]` on a forced
  source failure, and `mergeable: UNKNOWN` recorded (no retry).
- **`run-agent.sh`** with fixture snapshots, incl. a **prompt-injection fixture**
  whose body tries to induce a `tier: auto comment/close` → assert well-formed
  outputs and that the injection cannot escalate past `apply.sh`.
- **Confinement acceptance test** (blocking): the adversarial-snapshot fixture
  from **Agent confinement** (Bash canary, subagent-spawn canary, network
  exfil, substantive-action demand, delimiter smuggling) must show none
  occurred.
- **`apply.sh --auto --dry-run`** → every ack guardrail rejects the ineligible
  fixtures and accepts the eligible one; type-whitelist drops a `tier:auto comment`;
  label-whitelist drops an unknown label; ack body is the policy template
  regardless of model `body`; malformed `actions.json` rejected wholesale.
- **`apply.sh` (approval) dry-run** → per-item y/n/edit; **edit redisplays and
  re-prompts**; edited text is what would post; `posted`-id guard skips an already
  applied action on re-run; staleness guard defaults to skip on a changed target.
- **Full `triage.sh` dry run** → lock, time-gated catch-up (no early run at 06:00;
  single run at 10:00 after a powered-off night), failure trap, `status.json`
  states, retention prune — before installing launchd.

## Out of scope (YAGNI)

- No GitHub Actions component (addable later for mechanical stale-labeling).
- No email/issue digest surface (local file + notification only).
- No auto-merge/close/substantive replies — always approval-tier.
- No dynamic maintainer discovery — static list in `policy.json`.
- No `pending→posted` ack reconciliation (at-most-once accepted).
