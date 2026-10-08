---
layout: post
title: "The patch passed. A week later, nobody could explain it."
description: "Session-Bench v1: twelve coding-agent harnesses ran the same short session. We scored how much of the work a reader can recover from the session files alone."
date: 2026-10-08
image: /assets/bench-social-card.png
summary: >-
  We ran the same small coding session in twelve agent harnesses, then tried
  to rebuild what happened from the session files alone: 31 checks, 100
  points, every score replayable. All twelve keep the conversation. They
  differ in how often they store each event, whether they record what the
  work cost, and whether a session is one thing you can copy. The leaders do
  nothing clever. This is a first release with stated limits, and some rules
  were corrected after results were known.
seo_title: "Session-Bench v1: what 12 coding agents leave behind"
---

The feature shipped on Friday. On Wednesday, a customer finds the edge case.

You open the project and see a plausible patch. A price calculation changed, a
delivery rule moved, three tests pass. What you cannot see is why. Did the agent
look at the failing output first? Which command failed, and with what exit code?
What did the file look like before the edit? How many tokens did the fix cost?

The code is still there. The record of the work is in a JSONL file, or a SQLite
database, or four of them, or partly nowhere.

**[Session-Bench v1]({{ '/bench/v1/' | relative_url }})** measures that record.

## A reconstruction test, not a model contest

The benchmark asks one question:

> **After the session ends, how much of the agent's work can another tool
> recover from the files the harness wrote?**

It does not score the code, the model, the price or the speed. Each harness ran
the same two-turn task three times: inspect a small project, run a check that
fails, receive a correction, edit one file, run the check again. An independent
observer recorded what really happened. Then a decoder read only the session
files, and a comparator checked 31 facts against the observer: every turn,
response, tool call, result and exit code, the file before and after, the model,
the token counts, the timestamps, and whether a plain reader can use the files
without the vendor's own code.

The 31 metrics add up to 100 points in five groups: record fidelity (30),
causality and context (20), usage and attribution (15), portability and openness
(20), durability and signal (15).

## The ranking

| Rank | Harness | Score | Model in the test |
|---:|---|---:|---|
| 1 | DeepSeek Harness CLI | 96.9 | deepseek-flash |
| 2 | Pi | 96.4 | gpt-5.5 |
| 3 | Copilot CLI | 96.0 | gpt-6-luna |
| 4 | OpenCode CLI | 94.4 | muse-spark-1.3 |
| 5 | Kimi Code | 91.2 | kimi-k2.7-code |
| 6 | Claude Code CLI | 89.3 | claude-sonnet-5 |
| 7 | OpenClaw | 88.1 | gpt-5.6-terra |
| 8 | Codex CLI | 87.5 | gpt-5.6-sol |
| 9 | Hermes | 86.4 | gpt-5.5 |
| 10 | Claude Desktop | 85.6 | claude-opus-5 |
| 11 | Antigravity | 82.7 | claude-sonnet-4-6 |
| 12 | Cursor CLI | 78.1 | cursor-grok-4.5 |

Codex Desktop writes the same format as Codex CLI and shares its row. Cursor
Desktop is not scored yet.

The model column is there for honesty, not for comparison. The harnesses did not
run the same model, and the benchmark does not grade the model. It grades the
files.

## What the numbers say

**Nobody loses the conversation.** Eleven of twelve harnesses score 30 of 30 on
record fidelity and 20 of 20 on causality. Turns, responses, tool calls, results
and the link between a call and its result all survive. Claude Desktop is the
one exception: it batches some tool results, so one result in four cannot be
tied to its call. If your only question is "what did the agent say and do", every
tool on this list can answer it.

**The spread comes from three other places.**

*Saying things once.* A reader that walks the session file from top to bottom
should meet each event one time. In OpenCode, Kimi, OpenClaw and Antigravity,
not one event passes that test: every prompt, call and result is stored more than
once, with no field that marks the later copies as copies. Codex passes for
3 events in 100. Pi stores each event once. The same waste shows in density: in
Pi, 79% of the stored bytes are session content; in OpenClaw, 3%.

*Counting tokens.* Nine harnesses store input, output and cache token counts
beside each response. Cursor CLI stores no usage at all in the session record.
Hermes keeps usage for one request of the session. Antigravity keeps counts but
no cache fields. Only four of the twelve also keep enough to add the
responses up and check them against a session total.

*Being one thing you can copy.* Five harnesses keep parts of a session in stores
that all sessions share, so there is no folder you can lift out and call "this
session". Two, Antigravity and Cursor CLI, need more than a standard tool to
read what they wrote. Claude Code, Claude Desktop and Codex write no format
version, so a reader cannot tell when the format changed under it.

**The leaders are plain.** DeepSeek Harness, Pi and Copilot CLI do nothing
clever. One append-only file or one small store per session, a version field,
usage on each response, few repeats. The harnesses that lose points mostly lose
them for storing more, not less.

## Read this before you quote a number

This is a first release, and it is not a pre-registered experiment.

- **One task, three runs.** The workload is a small synthetic two-turn fix. It
  says nothing about long sessions, sub-agents, crashes or compaction.
- **Rules moved while we worked.** Some scoring rules were written after the
  first captures. Where a rule was waived or corrected after results were known,
  the report says so: failed capture attempts were replaced for OpenClaw, Claude
  Desktop and Kimi, and OpenCode is scored with its first reading (94.4), not a
  leaner one that gave 97.4.
- **The duplicate score depends on what the reader must open.** A harness whose
  facts sit in one lean file does better than one that spreads them over several
  stores.
- **The checker has stated gaps.** For example, it compares the path and id of
  an edit, not its full text.
- **Reviews were done by separate AI agent sessions on the same machine,** plus
  four rounds of outside model review. No second human operator repeated the
  captures.

All of this is in the [report](https://github.com/jazzyalex/session-bench/blob/main/artifacts/survival-v1-release/REPORT.md), under "Notes on waived and corrected rules" and
"Known limits", and on the [bench page]({{ '/bench/v1/' | relative_url }}).

## Check it yourself

Every score can be recomputed. The release holds the sanitized session files of
all 36 runs, the scoring source, and one command per run that replays the 31
metrics from those files:

- [Report](https://github.com/jazzyalex/session-bench/blob/main/artifacts/survival-v1-release/REPORT.md)
- [Replay instructions](https://github.com/jazzyalex/session-bench/blob/main/artifacts/survival-v1-release/REPRODUCE.md)
- [Rubric](https://github.com/jazzyalex/session-bench/blob/main/docs/survival-v1/rubric.md)
- [How each row was decided](https://github.com/jazzyalex/session-bench/tree/main/docs/survival-v1/adapters), with every judgment call and its point value

If you think a row is wrong, the adapter document for that row lists the
judgment calls and what each one is worth. Dispute one, and the score follows.

## What to ask of your agent

You do not need a benchmark to use the idea. After your next agent session, find
the session file and ask four things. Can I open it with a standard tool? Does
each thing appear once? Does it say what the work cost? Can I copy this one
session somewhere else and still read it?

The patch will pass either way. The answers decide whether anyone can explain it
next week.

[Agent Sessions](https://jazzyalex.github.io/agent-sessions/?campaign=blog&ref=session-bench-v1)
is a free, local-only macOS browser for these session stores. Session-Bench is
maintained in its own repository,
[github.com/jazzyalex/session-bench](https://github.com/jazzyalex/session-bench),
and disputes are welcome there as issues.
