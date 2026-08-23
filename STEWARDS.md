# Stewards

Agent Sessions reads local session history from a lot of coding agents. Those agents keep
changing their file formats. A **steward** is a person who uses one of them and checks, a
few times a year, that Agent Sessions still reads it correctly.

That is the whole job. One agent, your own installation, your own sessions.

## What a steward does

- Looks after **one** agent.
- Gets pinged when that agent's format needs a re-check — about 2–3 times a year.
- Runs one command against their own sessions, and reports what it says. Roughly
  10 minutes.
- If the format changed, attaches the redacted sample the tool produces to an issue.

## What a steward does not do

- No commit rights. No review duty.
- No code. You never have to open Xcode or write Swift.
- No support rota, no response deadline. If you're busy, say so or say nothing — the agent
  moves to best-effort and that's fine.
- No sharing of real transcripts. The check tool redacts before anything leaves your Mac,
  and you decide what to attach. Nothing in the job above ever publishes your session
  content.

## Sometimes asked, never expected

Two things occasionally come up that are **not** part of the job. Both are one-off, both are
opt-in, and "no" is a complete answer that changes nothing about your stewardship.

- **An end-to-end resume check.** Some agents are supported from their installed help and
  reader evidence, but nobody on the project could authenticate the CLI to confirm that
  Resume actually reopens a session. If you can run it once and say whether it worked, that
  closes the last hole in the support matrix. The footnotes under the table below name the
  agents waiting on this.
- **A screenshot for the release page.** Agent Sessions can only show an agent someone
  actually runs, so the maintainer cannot capture a session for an agent he does not have.
  This one is different from everything else here: **a screenshot is unredacted transcript.**
  The redaction promise above covers the check tool, and it cannot cover a picture. So if you
  are asked, you choose what is on screen, you take the capture, you look at it, and nothing
  is published until you say so. Declining is genuinely fine — a release does not need it.

## What a steward gets

Named credit in the table below, and on the project site's support page as it is built out.
Every verification run is a public, dated record with your handle on it. Anything from the
optional list above is credited the same way.

## Sign up

Open the [steward signup form](https://github.com/jazzyalex/agent-sessions/issues/new?template=steward-signup.yml)
and name the agent you use. If the agent you want isn't supported yet, start with the
[new agent source form](https://github.com/jazzyalex/agent-sessions/issues/new?template=new-agent-source.yml)
instead — see [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

The check itself is one command:

```bash
./scripts/steward_check.py <agent>
```

It compares your agent's sessions against the recorded baseline and, if the format moved,
writes a redacted sample you can attach to an issue.

## Tiers

- **Maintained** — the maintainer uses this agent daily and verifies it himself.
- **Steward-verified** — a named steward re-checks the format and the date below is theirs.
- **Best-effort** — no steward yet. It stays in the automated weekly format check while the
  maintainer can run it, but nobody is on the hook for it and drift can sit unfixed.

## Who looks after what

| Agent | Steward | Last verified | Tier |
|---|---|---|---|
| Codex | @jazzyalex (maintainer) | 2026-08-13 · 0.147.0 | Maintained |
| Claude Code | @jazzyalex (maintainer) | 2026-08-13 · 2.1.220 | Maintained |
| Cursor Agent | steward wanted | 2026-08-13 · 2026.8.11 | Best-effort |
| GitHub Copilot CLI | steward wanted | 2026-08-13 · 1.0.79 | Best-effort |
| OpenCode | steward wanted | 2026-08-17 · 1.18.18 | Best-effort |
| Antigravity CLI | steward wanted | 2026-08-13 · 1.1.12 | Best-effort |
| Pi | steward wanted | 2026-08-17 · 0.84.2 | Best-effort |
| Kimi Code | steward wanted | 2026-08-17 · 0.36.1 | Best-effort |
| Grok CLI | steward wanted | 2026-08-17 · 1.0.4 | Best-effort |
| OpenClaw | steward wanted | 2026-08-13 · 2026.7.1 | Best-effort |
| Hermes | steward wanted | 2026-06-24 · 0.17.0 | Best-effort |
| Qwen Code | steward wanted | 2026-08-17 · 0.14.3 (see note) | Best-effort |
| Devin CLI | steward wanted | 2026-08-18 · 3000.3.27 (see note) | Best-effort |
| fx (vercel-labs) | steward wanted | 2026-08-20 · 0.0.4 (see note) | Best-effort |

Dates and versions come from
[docs/agent-support/agent-support-matrix.yml](docs/agent-support/agent-support-matrix.yml),
which is the machine-readable record. This table is the human one; if they disagree, the
matrix is right.

Droid is not in the table on purpose: it is legacy-only — existing sessions still read,
but the agent is excluded from active format checks and takes no steward.

Honest footnotes:

- **Devin CLI.** Verified against the installed CLI 3000.3.27 (0becb483) with a schema
  probe over 253 on-disk sessions in the shared `sessions.db`. Resume is implemented from
  installed help and reader evidence with hermetic tests, not an end-to-end run, because
  authentication blocked a disposable run; it stays untested until someone with an
  authenticated Devin login closes it. Devin is in the weekly format monitoring set as of
  2026-08-22, so `./scripts/steward_check.py devin` runs — but only on a machine with the
  CLI installed, which is the same authenticated login the resume check needs.
- **Qwen Code.** Verified against 0.14.3 transcripts. The installed CLI is 0.21.13, but the
  Qwen OAuth free tier was discontinued on 2026-04-15, so no newer transcript can be
  captured on this machine without a paid plan or an alternate provider. Newer Qwen builds
  are unverified. A steward with a working Qwen account would close this outright — it is
  the single most useful agent to adopt.
- **Hermes.** Held at 0.17.0 since 2026-06-24. The automated driver stopped producing a
  usable sample, so newer Hermes builds have no fresh evidence either way.
- **fx (vercel-labs).** Verified against the installed fx 0.0.4 with a schema survey of
  the on-disk sessions under `~/.fx/sessions`: transcripts come from each session's
  `checkpoint.json`, sidecars carry identity/workspace/title/model, and `fx --help`
  advertises `--resume <id>` and `--continue`. Resume is implemented from that help and
  reader evidence with hermetic tests, not an end-to-end run; it stays untested until
  someone with an authenticated fx login closes it. fx is in the weekly format
  monitoring set as of 2026-08-23, so `./scripts/steward_check.py fx` runs — but only
  on a machine with fx sessions on disk. The format is young (schema_version 3
  sidecars, event_log_v1 storage), so drift is likelier than for the older agents.
