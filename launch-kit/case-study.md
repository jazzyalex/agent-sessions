# Agent Sessions: the tool a single agent vendor structurally can't build

*A first-person case study by Alexander Malakhov — solo builder, macOS.*

## The problem was in my own filesystem

I started Agent Sessions on September 19, 2025, because I kept losing work I had already done.

Not my work — the agents'. I was running Codex and Claude Code every day, and both of them wrote everything to disk: prompts, tool calls, diffs, the reasoning in between. That history was sitting right there in `~/.codex/sessions` and `~/.claude/projects`, and it was effectively unreachable. If I wanted to find the session where an agent had solved a gnarly migration two weeks earlier, my options were `grep` across thousands of JSONL files or give up and re-derive it. I gave up a lot.

So I built the thing I wanted: a local Mac app that reads those files and turns them into one searchable, browsable view. No account, no upload, no backend. Point it at the folders your agents already write to, and your history becomes a first-class artifact instead of exhaust.

## 0 to ~700 weekly active users, with zero marketing

I have never run an ad, bought a placement, or written a launch thread. Every user arrived by word of mouth, a GitHub search, or a link someone dropped in a Slack. Ten and a half months in, the honest numbers are:

- **750 GitHub stars, 49 forks, 3 open issues.**
- **~700 weekly active users.**
- **11,431 total downloads** across releases. When v4.0 shipped on June 28, 2026, it took 294 downloads in its first three days.

The part I find most interesting isn't the totals — it's the shape of the curve. A tool in a fast-moving category is "supposed" to spike and decay. This one did the opposite. Growth averaged around 55 stars a month for the first four months, then *accelerated*: 133 in March 2026, 100 in April, and roughly 80 a month every month since. Momentum built as the category matured, not as it faded. That told me something about the problem was structural, not novelty-driven.

## The thesis: the category narrowed, but the surviving job got stronger

When I started, "a viewer for your coding-agent history" was a broad, slightly speculative bet. Since then, the first-party vendors have moved in. Codex, Claude Code, and others added their own session lists, resume features, and history surfaces. If you only used one agent, a lot of what Agent Sessions did got absorbed into the tools themselves.

It would have been easy to read that as "the category got eaten." I read it as the opposite. The category narrowed to its durable core, and that core got *harder* for anyone but an independent tool to serve.

Here's why. Nobody runs one agent CLI anymore. In a single week I'll use Codex for one repo, Claude Code for another, and try something new on a side project. My history is now smeared across ten different ecosystems, each with its own storage, its own schema, and its own idea of what a "session" even is. And this is the part a first-party tool structurally cannot fix: **Codex will never index your Claude sessions.** Claude will never surface your Cursor transcripts. No single vendor has an incentive — or permission — to unify a competitor's data. Cross-agent history, search, and analytics is precisely the job that only a neutral, local, third-party tool can do. The vendors validated the category and then, by their own boundaries, handed me the part they can't touch.

Today Agent Sessions reads ten sources: Codex, Claude Code, Cursor, OpenCode, GitHub Copilot CLI, Hermes, OpenClaw, Antigravity, Pi, and Kimi Code. That list is the moat. Every agent a developer adds makes a unified view *more* necessary, not less.

## What I learned that almost nobody else has: ten ecosystems of session data

The genuinely rare expertise I picked up building this isn't UI or Swift. It's that I now understand, in detail, how ten different agent ecosystems persist a conversation to disk — and how little they agree.

Some write append-only JSONL, one event per line, and you reconstruct the session by folding the log forward. Others keep a SQLite database (OpenCode's `opencode.db`, Hermes' `state.db`) and you're reverse-engineering a schema that was never meant to be read by anyone else. Cursor scatters transcript content and chat metadata across separate local stores that you have to rejoin. They disagree on almost everything that matters: how a tool call and its output are represented, how messages map to a project or working directory, how timestamps are recorded, what happens to a "deleted" or archived session, whether reasoning is even persisted.

There is no standard here, and there is no spec. The only way to learn it is to sit with each format until it makes sense, handle the edge cases real sessions produce, and keep up as vendors change their storage between releases. I don't know many people who have done that for one agent, let alone ten. When people ask what a solo project like this is *worth*, that map — of where the industry actually keeps its agent memory and how inconsistent it is — is the asset I'd point to first.

It also stopped being a solo effort in the way that matters most. External contributors have sent real feature PRs: Warp terminal support, CodeBuddy support, OpenCode integration, Copilot CLI discovery fixes. People who hit a gap in their own workflow fixed it in mine. For a local-first tool with no telemetry — where I genuinely cannot see what anyone does — unsolicited PRs are the clearest signal I have that the thing is load-bearing in other people's day.

## The honest part: maintenance mode, or an undervalued asset?

I won't pretend the last few months felt like a rocket. Once the vendors shipped their own session features, it was reasonable to wonder whether Agent Sessions had quietly slid into maintenance mode — a useful utility, kept alive, past its moment.

The data argues the other way, and I've come around to it. A tool that keeps *accelerating* ten months in, entirely on word of mouth, that keeps attracting outside contributors, and that sits on the one piece of the problem the incumbents are structurally barred from solving — that's not a project winding down. That's an undervalued asset that hasn't been told its own story yet.

That's the honest arc: I built a utility to scratch my own itch, watched the market seem to close in, and realized the market had actually cleared the field around the one thing I was uniquely positioned to keep doing. Local-first, cross-agent, no backend, no telemetry — reading the memory that a dozen coding agents leave on your machine and making it yours.

I recently applied to Anthropic's Claude for Open Source program. Whatever comes of it, I'd rather be the person who kept building the neutral tool than the one who assumed the category was over because the big vendors showed up. They showed up to validate it. The part they left on the table is the part worth having.

*Agent Sessions is open source (MIT) and local-only. github.com/jazzyalex/agent-sessions*
