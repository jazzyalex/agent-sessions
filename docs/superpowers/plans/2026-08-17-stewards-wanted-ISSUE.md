# Prepared issue: "Stewards wanted"

Draft body for the pinned issue. The owner posts it. Suggested title:
**Stewards wanted: adopt one agent, keep it verified**
Suggested labels: `steward`, `help wanted`, `pinned`.

---

Agent Sessions reads local session history from a dozen coding agents. Those agents change
their file formats whenever they feel like it, and the only reliable evidence that a format
still reads correctly is a real installation with real sessions in it.

I have those for Codex and Claude Code. For the rest, I'm running on borrowed time.

So: **stewards**. A steward looks after one agent. You get pinged two or three times a year,
run one command against your own sessions, and say whether the format still reads correctly.

```bash
./scripts/steward_check.py <agent>
```

It compares your sessions against the recorded baseline and, if the format moved, writes a
redacted sample you can attach to an issue. About ten minutes.

What it isn't: no commit rights, no code, no review duty, no response deadline. You never
send a real transcript — the tool redacts first and you decide what to attach. If you go
quiet, the agent moves back to best-effort and nothing bad happens.

What you get: your name on the entry in
[STEWARDS.md](https://github.com/jazzyalex/agent-sessions/blob/main/STEWARDS.md) and on the
support page, with a dated public record of each verification.

## Agents with no steward

- **Qwen Code** — the most useful one to adopt. Verified against 0.14.3 transcripts only.
  The Qwen OAuth free tier was discontinued on 2026-04-15, so I can't capture a newer
  transcript here without a paid plan. If you have a working Qwen account, you can close a
  gap I can't.
- **Hermes** — held at 0.17.0 since June, because the automated sample driver stopped
  producing anything usable. Needs someone who actually runs Hermes.
- **Cursor Agent** — Cursor ships fast and its CLI has changed shape more than once. Needs a
  regular Cursor CLI user on macOS.
- **GitHub Copilot CLI** — the busiest format of the lot; it has added new event types
  several times this year. All additive so far, which is exactly why it should be watched.
- **OpenCode** — has already changed its storage layout once. Worth having eyes on.
- **OpenClaw** — its versions are dated, it moves weekly, and its auth setup on my machine
  is a mess. Someone whose OpenClaw simply works would help a lot.
- **Antigravity CLI** — writes markdown brain artifacts rather than a transcript, which
  makes automated sampling fragile. A human with real sessions is worth more here than a
  script.
- **Pi** — stable so far. Low-effort adoption if you use Pi.
- **Kimi Code** — reasonably new support, and its journal format has already surprised me
  once. Wants a regular user.
- **Grok CLI** — newest of the bunch, including subagent nesting that Grok's own session list
  doesn't show. Needs someone using it in anger.

## To adopt one

Open the [steward signup form](https://github.com/jazzyalex/agent-sessions/issues/new?template=steward-signup.yml),
or just reply here with the agent you use and I'll take it from there.

If your agent isn't supported at all yet, start with the
[new agent source form](https://github.com/jazzyalex/agent-sessions/issues/new?template=new-agent-source.yml)
instead — [docs/CONTRIBUTING.md](https://github.com/jazzyalex/agent-sessions/blob/main/docs/CONTRIBUTING.md)
explains what evidence makes a proposal usable.
