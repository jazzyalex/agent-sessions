---
layout: post
title: "A prompt-injection-safe GitHub triage agent: give the model no tools"
description: "Why an LLM that triages untrusted GitHub issues should have zero tools — the tool-less design, the adversarial confinement test that proves it, and the repo-takeover flaw that motivates it."
date: 2026-07-16
image: /assets/blog/2026-07-16-injection-safe-triage-card.png
summary: >-
  In January 2026 a researcher took over a GitHub repo by opening one issue at a
  triage bot. The fix for that class of bug isn't better input filtering; it's
  giving the model nothing to act with. Here's a daily triage agent built
  tool-less by construction — text in, text out, a human posting at the end —
  and the adversarial test that checks the confinement against the live model
  before it runs.
---

In January 2026, a security researcher took over a GitHub repository by opening
one issue. The repo used Anthropic's Claude Code GitHub Action to triage
issues. RyotaK of GMO Flatt Security wrote an issue that read like an
error message and refined it until the model "recovered" by running the
commands buried inside. That walked the action into reading
`/proc/self/environ`, where the credential for minting an OIDC token was
sitting; Anthropic's backend traded that token for a GitHub App
installation token with write access to code, issues, and workflows. One issue
produced full write access. Anthropic rated it 7.8, paid a bounty, and shipped
the fix in [claude-code-action
v1.0.94](https://flatt.tech/research/posts/poisoning-claude-code-one-github-issue-to-break-the-supply-chain/).

The specific bug was an authorization check that trusted any actor whose name
ended in `[bot]`. The general problem is older and unsolved: point a tool-armed
LLM at text an attacker controls, and one well-written paragraph can make it do
what the attacker wrote, not what you asked. This is indirect prompt
injection, and there is no known way to sanitize it away. The action's own
security notes admit as much: they strip HTML comments and hidden characters,
then warn that new bypasses will emerge. Filtering raises the bar. It does not
close the door.

I wanted the same job without that door: a small task that runs over my two
repositories every morning, reads the new issues, PRs, and discussions, drafts
a digest and any replies worth sending, and lets me approve each one before it
posts. That is exactly the workload that just got someone owned. Here is how to
run it so an injection has nothing to hold onto.

<figure class="post-figure">
<style>
.tf-fig { overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 0 auto; max-width: 760px; }
.tf-svg { width: 100%; height: auto; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
.tf-box { fill: #f6f8fa; stroke: #d0d7de; }
.tf-model { fill: #eef1f4; stroke: #b7bfc7; }
.tf-t { fill: #1f2328; font-size: 13px; }
.tf-h { fill: #1f2328; font-size: 13.5px; font-weight: 600; }
.tf-mut { fill: #57606a; font-size: 12px; }
.tf-danger { stroke: #d1242f; fill: #d1242f; }
.tf-danger-t { fill: #d1242f; font-size: 12.5px; font-weight: 600; }
.tf-danger-box { fill: #fff0f0; stroke: #f0b9bd; }
.tf-safe { stroke: #1a7f37; fill: #1a7f37; }
.tf-safe-t { fill: #1a7f37; font-size: 12.5px; font-weight: 600; }
.tf-safe-box { fill: #eef6f0; stroke: #a7d3b3; }
.tf-arrow { stroke: #57606a; stroke-width: 1.5; fill: none; }
.tf-wall { stroke: #1a7f37; stroke-width: 2.5; }
.tf-ah { fill: #57606a; }
.tf-ah-d { fill: #d1242f; }
@media (prefers-color-scheme: dark) {
  .tf-box { fill: #1c1c1e; stroke: #3a3a3c; }
  .tf-model { fill: #242426; stroke: #48484a; }
  .tf-t, .tf-h { fill: #e6e6e6; }
  .tf-mut { fill: #9a9a9e; }
  .tf-danger, .tf-danger-t { fill: #ff6b6b; stroke: #ff6b6b; }
  .tf-danger-box { fill: #2a1416; stroke: #5c2b2f; }
  .tf-safe, .tf-safe-t { fill: #3fb950; stroke: #3fb950; }
  .tf-safe-box { fill: #10251a; stroke: #2b5236; }
  .tf-arrow { stroke: #9a9a9e; }
  .tf-wall { stroke: #3fb950; }
  .tf-ah { fill: #9a9a9e; }
  .tf-ah-d { fill: #ff6b6b; }
}
</style>
<div class="tf-fig">
<svg class="tf-svg" viewBox="0 0 760 380" role="img" aria-label="Two architectures for pointing an LLM at an attacker-controlled issue. With tools, an injection reaches secrets and write access. Tool-less, it can only produce a draft a human reviews.">
  <defs>
    <marker id="tfArr" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
      <path d="M0,0 L8,4 L0,8 Z" class="tf-ah"/>
    </marker>
    <marker id="tfArrD" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
      <path d="M0,0 L8,4 L0,8 Z" class="tf-ah-d"/>
    </marker>
  </defs>

  <!-- Panel A: tools -->
  <text x="30" y="28" class="tf-h">Agent with tools, in CI</text>
  <rect x="30" y="44" width="300" height="40" rx="7" class="tf-box"/>
  <text x="45" y="69" class="tf-t">Attacker's issue text</text>
  <line x1="180" y1="84" x2="180" y2="112" class="tf-arrow" marker-end="url(#tfArr)"/>
  <rect x="30" y="112" width="300" height="46" rx="7" class="tf-model"/>
  <text x="45" y="134" class="tf-t">LLM</text>
  <text x="45" y="150" class="tf-mut">shell · files · network</text>
  <line x1="180" y1="158" x2="180" y2="188" class="tf-danger" stroke-width="1.5" marker-end="url(#tfArrD)"/>
  <rect x="30" y="188" width="300" height="120" rx="7" class="tf-danger-box"/>
  <text x="45" y="212" class="tf-t">reads /proc/self/environ</text>
  <text x="45" y="236" class="tf-t">mints an OIDC → write token</text>
  <text x="45" y="260" class="tf-t">pushes to your repo</text>
  <text x="45" y="292" class="tf-danger-t">injection reaches actions</text>

  <!-- Panel B: tool-less -->
  <text x="430" y="28" class="tf-h">Tool-less agent</text>
  <rect x="430" y="44" width="300" height="40" rx="7" class="tf-box"/>
  <text x="445" y="69" class="tf-t">Attacker's issue text + canaries</text>
  <line x1="580" y1="84" x2="580" y2="112" class="tf-arrow" marker-end="url(#tfArr)"/>
  <rect x="430" y="112" width="300" height="46" rx="7" class="tf-model"/>
  <text x="445" y="134" class="tf-t">LLM</text>
  <text x="445" y="150" class="tf-mut">no tools · text in, text out</text>
  <!-- safe chain -->
  <line x1="580" y1="158" x2="580" y2="188" class="tf-arrow" marker-end="url(#tfArr)"/>
  <rect x="430" y="188" width="300" height="34" rx="7" class="tf-safe-box"/>
  <text x="445" y="210" class="tf-t">text: digest + draft replies</text>
  <line x1="580" y1="222" x2="580" y2="240" class="tf-arrow" marker-end="url(#tfArr)"/>
  <rect x="430" y="240" width="300" height="34" rx="7" class="tf-safe-box"/>
  <text x="445" y="262" class="tf-t">a human approves</text>
  <line x1="580" y1="274" x2="580" y2="292" class="tf-arrow" marker-end="url(#tfArr)"/>
  <rect x="430" y="292" width="300" height="34" rx="7" class="tf-safe-box"/>
  <text x="445" y="314" class="tf-t">post one reply</text>
</svg>
</div>
<figcaption>Same input, two blast radii. A tool-armed agent that "recovers" from a malicious issue can reach secrets and write access. A tool-less one has nothing to call; the worst an injection produces is a draft a human throws away.</figcaption>
</figure>

## The wrong fix first: fencing a tool-using agent

My first attempt kept the agent and fenced it with flags. Claude Code accepts
`--allowedTools` and `--disallowedTools`, but a deny-list is a pre-approval
list, not a sandbox. The process still runs with your filesystem, environment,
and network reachable; the flags govern which named tools the model may call,
not what the process can touch. If `Task`, `Agent`, `Skill`, or `Workflow`
survive, an injection can spawn a subagent that arrives with its own tools. You
bar the front door and leave a door that builds new doors. I could not convince
myself the fence held, so I removed the tools instead.

## The design: tool-less by construction

The agent that reads untrusted text does one thing: turn text into text. No
shell, no files, no network, no subagents. Everything it needs arrives in the
prompt; everything it produces leaves on stdout. Three plain scripts sit
around it.

`gather.sh` runs first and does all the reading: it calls `gh` and writes a
snapshot of open issues, PRs, discussions, and recent releases to a file.
The model fetches nothing.

`run-agent.sh` feeds that snapshot to the model as data and takes back text:

```
claude -p --output-format text --strict-mcp-config \
  --disallowedTools Bash WebFetch WebSearch Task Agent Workflow Skill \
                    NotebookEdit Edit Write Glob Grep TodoWrite \
  < prompt.txt
```

The prompt goes in on stdin, the process runs in an empty temporary directory,
and the disallow list names every tool that reads, writes, fetches, or spawns.
What is left is a language model with nothing to invoke.

`reply.sh` runs afterward, and only when I say so. It posts one approved reply
by id with `gh`. The model never holds the token and never triggers the write.

Because the model cannot write files, it hands everything back as structured
text. The contract is three markers:

```
<<<DIGEST>>>
...markdown digest...
<<<REPLIES>>>
[{"id":"R1","repo":"me/app","number":123,"kind":"issue","body":"draft reply"}]
<<<END>>>
```

An `awk` pass extracts the first `DIGEST` and `REPLIES` blocks; `jq` validates
the array. If the model wanders off the format, the run exits non-zero and I
get a plain fallback digest. Drafts land in a file
for me to read, never in a queue that posts itself.

## Why this holds even though a flag is not a sandbox

`--disallowedTools` is still a flag, not a sandbox. What changed is how much is
left to protect. A tool-using agent permits some actions and blocks others, so
the blocked set has to be airtight. A tool-less agent permits none. There is no
allowed tool for an injection to route through, no subagent to spawn, and
nothing valuable in the process to reach: the working directory is empty and
the posting credential lives in a different script that runs later, under my
hand. The best a successful injection can manage is a convincing draft reply.
I read every draft; the cost is thirty wasted seconds of my morning.

<figure class="post-figure">
<style>
.cmp-wrap { overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 0 auto; max-width: 720px; }
.cmp-table { border-collapse: collapse; width: 100%; font-size: 14px; line-height: 1.45; }
.cmp-table th, .cmp-table td { text-align: left; vertical-align: top; padding: 8px 12px; border-bottom: 1px solid #d0d7de; }
.cmp-table thead th { border-bottom: 2px solid #d0d7de; font-weight: 600; }
@media (prefers-color-scheme: dark) {
  .cmp-table th, .cmp-table td { border-bottom-color: #2c2c2e; }
  .cmp-table thead th { border-bottom-color: #3a3a3c; }
}
</style>
<div class="cmp-wrap">
<table class="cmp-table">
<thead>
<tr><th>Design</th><th>Read repo secrets?</th><th>Take an action?</th><th>Worst case of an injection</th></tr>
</thead>
<tbody>
<tr><td>Tool-armed agent in CI</td><td>Yes</td><td>Yes (label, close, push, comment)</td><td>Repo takeover, as in the January 2026 chain</td></tr>
<tr><td>"Confined" with tool deny-flags</td><td>Sometimes (process still has fs/env; subagents can bring tools)</td><td>Sometimes</td><td>A fence you cannot fully verify</td></tr>
<tr><td>Tool-less + human approval</td><td>No</td><td>No</td><td>A draft reply you delete</td></tr>
</tbody>
</table>
</div>
<figcaption>The difference isn't how well each design filters the input. It's what remains reachable after the model has been talked into cooperating with the attacker.</figcaption>
</figure>

## Why not the built-in cloud triage?

Both vendors ship this workload as a feature. Claude Code Routines, a
research preview, runs scheduled sessions in Anthropic's cloud with full tool
access (shell, files, connectors) and no approval prompts mid-run. Its GitHub
triggers cover only pull-request and release events, so issue triage runs on
the clock, with daily caps by plan (Pro 5, Max 15, Team/Enterprise 25). Codex's
"automate bug triage" is the same shape in OpenAI's cloud; it will draft for
approval if you ask, but that gate is a sentence in your prompt, not a platform
boundary. The convenience is real: zero install, and someone else maintains and
runs it. This design trades that for local execution, a model with nothing to
invoke, and a gate that lives in the architecture.

<figure class="post-figure">
<div class="cmp-wrap">
<table class="cmp-table">
<thead>
<tr><th></th><th>Claude Code Routines</th><th>Codex bug triage</th><th>This design</th></tr>
</thead>
<tbody>
<tr><td>Where it runs</td><td>Anthropic's cloud</td><td>OpenAI's cloud</td><td>Your machine</td></tr>
<tr><td>Agent has tools</td><td>Yes (shell, files, connectors)</td><td>Yes</td><td>None</td></tr>
<tr><td>Who posts</td><td>The agent</td><td>The agent (draft gate if prompted)</td><td>You, per reply</td></tr>
<tr><td>Injection exposure</td><td>Full tool surface</td><td>Full tool surface</td><td>A draft you delete</td></tr>
<tr><td>Provider</td><td>Claude only</td><td>Codex only</td><td>Claude, via <code>claude -p</code></td></tr>
</tbody>
</table>
</div>
<figcaption>Same job, three trust models; only the local one makes the approval gate structural.</figcaption>
</figure>

## Prove it: the adversarial confinement gate

I do not trust arguments about model behavior, so the install tests the real
CLI before scheduling anything. `tests/test_confinement.sh` feeds the live
model a snapshot rigged with injection: an issue body ordering
it to ignore its instructions and run a command, a smuggled `REPLIES` block
trying to forge an approved post, and two canary strings, `__BASH_CANARY__` and
`__SUBAGENT_CANARY__`, that only surface if the model shells out or spawns a
subagent. The test asserts the run touched nothing, tripped no canary, and
produced only the text contract. Nine of nine must pass before the `launchd`
job installs. The design is the claim; the gate is the evidence, checked
against the model that will actually run.

## Grounding, so it doesn't lie to people

One rule is about honesty, not safety. A triage agent's most tempting
mistake is telling a reporter their bug is fixed when it guessed. The gather
step pulls the last few releases, and the prompt forbids claiming a fix shipped
unless a release postdates the report; otherwise the draft says a fix is in
progress. The model checks fetched facts instead of its own optimism.

## Where this fits, and where it doesn't

The design is narrow on purpose. It fits a read-and-draft job with a human at
the end, not an agent that labels, closes, or pushes on its own; the moment the
model drives a write, you are back to securing a tool-using agent. The model
can still be talked into a bad draft; the guarantee is not that it behaves but
that when it misbehaves, the blast radius is a suggestion I can delete.

There is a quieter benefit. Each run is a headless `claude -p` session and
writes the same transcript any Claude Code session does. When a digest looks
off, I don't guess; I open the run in [Agent
Sessions](https://github.com/jazzyalex/agent-sessions), the macOS app I build
for reading agent transcripts, and see exactly what went in and what came back.
Scheduled agents are becoming ordinary, and almost none have a "what did this
actually do last night" view. The transcripts are already on disk. They just
need reading.

Agent Sessions is free, local-only, has no telemetry, and opens those files
read-only; the source is [on
GitHub](https://github.com/jazzyalex/agent-sessions), and more posts like this
one live at [/blog/]({{ '/blog/' | relative_url }}).
