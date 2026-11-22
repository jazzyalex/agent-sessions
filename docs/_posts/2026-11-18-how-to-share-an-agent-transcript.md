---
layout: post
title: "The Whole Transcript, Including the Parts Nobody Read"
seo_title: "What an AI Agent Transcript Export Exposes in a Public Bug Report"
description: "A synthetic Agent Sessions 6.6 export, the project path a literal search misses, and what a maintainer actually needs in a public issue."
date: 2026-11-18
published: false
summary: >-
  Maintainers who ask for the full transcript are usually right to want it.
  Plenty of the people uploading one have never had a reason to look inside
  it. A small synthetic export shows what rides along.
---

<div class="post-export-story" markdown="1">

<p class="post-export-intro">Give the Agent Sessions 6.6 Markdown exporter this little session, with a single image embedded in the transcript, and it writes out a Markdown file and puts a folder beside it.</p>

<figure class="post-figure post-export-sample">
  <pre><code>invoice-bug.md
invoice-bug-assets/
  └── image-sample-1.png</code></pre>
  <figcaption>An isolated run of the Agent Sessions 6.6 export code with pre-parsed synthetic input. The PNG is a byte-for-byte copy of the supplied image.</figcaption>
</figure>

The session behind those two files was never a real session. The user, the
project, the billing account, and the key are all invented. The input was
pre-parsed synthetic events handed straight to the 6.6 Markdown and
image-writing code. One prompt, one shell command, and one 68-byte PNG.
The export is short enough to read in under a minute. It still gives you
plenty to miss.

Those of us who maintain tools in this space have a reflex. When an issue
arrives with an error message and not much else, we ask for the whole
transcript. It is a good reflex. By the time a bug reaches an issue, the
reporter has already decided which parts of the story matter. If the second
command failed because of something the first one did, they will quite
reasonably paste the second one (it's the one with the error in it). Then
some maintainer spends a Friday afternoon trying to coax that error out of a
perfectly healthy checkout.

But before we make "attach the full transcript" the first line of every
issue template, we should admit that we have no idea how many of the people
we're asking have ever opened an export in a text editor. Plenty of them know
Node cold and can tell you exactly what `ENOENT` means. Plenty of them, I'd
wager, have no particular reason to know what the file they're about to drag
into a comment box carries. It holds their home directory in a Markdown
table, again in a JSON string, and again in the text of the error. The folder
next to it holds an image from earlier in the session, too.

The filenames do some of that work on their own. `invoice-bug.md` and
`invoice-bug-assets/` obviously belong together. If you're keeping the session
for yourself, zipping them together is exactly right. It is also exactly how
an image with nothing to do with a shell command ends up attached to an issue
about one.

The standard advice is to search the export before posting it. That advice
is sound. Those of us who give it tend to underestimate how much it
depends on already knowing what to search for. A literal search of this export
for `/Users/mara/Work/Fir Billing` finds two matches, one in the header table
and one in the error. It misses the third, because the tool call's JSON
escapes every slash.

<figure class="post-figure post-export-sample">
  <pre><code>"workdir" : "\/Users\/mara\/Work\/Fir Billing"</code></pre>
  <figcaption>The JSON escapes each forward slash. A literal search for the original path skips this line.</figcaption>
</figure>

A case-insensitive search for just `mara` finds four. One of those hits gives you the location of the raw session file, under
`/Users/mara/.codex/sessions/`. The better habit is to search short fragments
of the username, project name, host, and account ID, with case ignored. This
command prints only the matching fragments and their line numbers, so the
first pass can keep whole log lines off the screen.

```sh
rg -n -i -o -F -e mara -e fir -e acct_example -- invoice-bug.md
```

Then there is the tool output. The export tucks it into a disclosure, which
is closed by default.

<figure class="post-figure post-export-sample">
  <details class="post-report-template">
    <summary>Tool output <code>exec_command</code></summary>
    <pre><code>Exit code: 1
<mark>account_id=acct_example_fir
endpoint=https://billing.fir.example/import?tenant=fir-demo
BILLING_API_KEY=demo-value-not-a-credential</mark>
ENOENT: no such file or directory, open '/Users/mara/Work/Fir Billing/test data/invoice.json'</code></pre>
  </details>
  <figcaption>The tool output from the fixture. The highlighted lines are in the file even when the disclosure is closed.</figcaption>
</figure>

The script knew its account, its billing endpoint, and which tenant it meant
to bill. The one thing it couldn't find was the invoice. (The fixture stops at the file error.) Those
highlighted lines are in the Markdown from the moment the file is written. A
closed disclosure keeps them off the rendered page until someone clicks the
triangle. Anyone who opens the raw file sees them right away.

We ship that exporter, and I'd rather it keep too much than too little. The
point of an export is to understand a session a week later, so the header,
the working directory, the tool calls, and the images all have to survive.
In the isolated run, the embedded PNG came out byte-for-byte identical to
the one that went in. The run didn't test file-backed images. The source
code shows that an image already living in a file gets its local path written
into the Markdown, and that path may well include a username. Either way, open
the actual attachment before sending it. If it's a screenshot, the terminal
tabs and the notification in the corner deserve the same scrutiny as the
error in the middle. [Agent Sessions 6.6 export code](https://github.com/jazzyalex/agent-sessions/blob/v6.6/AgentSessions/Views/TranscriptPlainView.swift#L2887-L2910)

## The issue I'd file

I'd start from a blank file with the version, the steps, and the expected
result, and then add these four lines.

<figure class="post-figure post-export-sample">
  <pre><code>Working directory: ~/work/Demo Billing
Command: node scripts/load-fixture.mjs "test data/invoice.json"
Exit code: 1
ENOENT: no such file or directory, open '~/work/Demo Billing/test data/invoice.json'</code></pre>
  <figcaption>The public excerpt uses invented directories and keeps the space and quoting from the original command.</figcaption>
</figure>

Both spaces survive, in `Demo Billing` and in `test data`, and they should.
Whoever diagnoses this needs to know that the command was quoted and the
paths had spaces in them. If the spaces matter, tidying them away could cost the maintainer the
very afternoon the excerpt was supposed to save. If the bug reproduces in a
throwaway project, say so and share that project instead. If the bug is in
the transcript reader itself, send the synthetic events it needs in their
original order. Keep a missing field, `null`, `""`, and `[]` distinct from
one another, because any of them might be the thing the reader tripped on. [Agent Sessions fixture guidance](https://github.com/jazzyalex/agent-sessions/blob/main/docs/CONTRIBUTING.md#add-an-agent)

Before posting, make one more pass through the issue preview and open every
attachment, especially the one with the innocuous filename. If a working
credential has already made it into an issue, revoke or rotate it first and
clean up the post second. If the failing input has to stay private, send the
version, the steps, and the error, and let the maintainer ask for whatever
comes next.

<details class="post-report-template">
  <summary>Copyable bug report template</summary>
  <pre><code>Agent, version, and surface (CLI, desktop, or editor):
OS and viewer version, if relevant:

Steps to reproduce:
1.
2.

Expected:
Actual:

Minimal excerpt or synthetic fixture:
What I changed in the excerpt:
Reproduces with the shared example: Yes / No / Untested</code></pre>
</details>

If you're still looking for the original session file, see
[where coding agents store session history]({{ site.baseurl }}{% post_url 2026-07-11-where-agents-store-history %}).

</div>
