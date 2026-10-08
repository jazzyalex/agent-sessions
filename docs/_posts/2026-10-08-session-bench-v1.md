---
layout: post
title: "Same bug fix, 12 coding agents: 19 KB to 697 KB on disk, and what you can get back"
description: "Session-Bench v1: we ran one two-prompt bug fix in twelve coding-agent harnesses and rebuilt each session from its files alone. Scores, charts, and what each one keeps."
date: 2026-10-08
image: /assets/session-bench-v1-social-card.png
summary: >-
  We ran the same two-prompt bug fix through twelve coding-agent harnesses,
  three times each, and rebuilt every session from the files alone: 31 checks,
  100 points, every score replayable. All twelve keep the conversation. The
  record of the same fix takes 19 KB in Pi and 697 KB in OpenClaw, four
  harnesses never write an event only once, and four of twelve record token
  usage that adds up to a stated total. DeepSeek Harness is first at 96.9 and
  Cursor CLI last at 78.1.
seo_title: "Session-Bench v1: session files of 12 coding agents, scored"
bench:
  agents:
  - rank: 1
    id: deepseek-harness-cli
    name: DeepSeek Harness
    score: '96.9'
    build: 0.2.0-rc.2
    model: deepseek-flash
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '15'
      max: 15
      pct: 100.0
      tone: full
    - label: Portability
      abbr: Portable
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Durability
      abbr: Durable
      value: '11.9'
      max: 15
      pct: 79.3
      tone: mid
    kb: 193
    session_kb: 108
    content_pct: 56
    copies: '1.4'
    blocks:
    - 100
    - 41
    once_pct: 63
    events: 126
    statements: 178
    once: 79
    stamps_pct: 92
    grid:
    - full
    - part
    - full
    - full
    - full
    - full
    - part
    kb_pct: 27.7
  - rank: 2
    id: pi
    name: Pi
    score: '96.4'
    build: 1.0.0
    model: gpt-5.5
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '12'
      max: 15
      pct: 80.0
      tone: mid
    - label: Portability
      abbr: Portable
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Durability
      abbr: Durable
      value: '14.4'
      max: 15
      pct: 96.0
      tone: mid
    kb: 19
    session_kb: 15
    content_pct: 79
    copies: '1.0'
    blocks:
    - 100
    once_pct: 100
    events: 45
    statements: 45
    once: 45
    stamps_pct: 100
    grid:
    - full
    - full
    - full
    - none
    - full
    - full
    - full
    kb_pct: 2.7
  - rank: 3
    id: copilot
    name: Copilot CLI
    score: '96.0'
    build: 1.0.91
    model: gpt-6-luna
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '15'
      max: 15
      pct: 100.0
      tone: full
    - label: Portability
      abbr: Portable
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Durability
      abbr: Durable
      value: '11'
      max: 15
      pct: 73.3
      tone: mid
    kb: 182
    session_kb: 74
    content_pct: 41
    copies: '1.8'
    blocks:
    - 100
    - 78
    once_pct: 43
    events: 49
    statements: 87
    once: 21
    stamps_pct: 100
    grid:
    - full
    - part
    - full
    - full
    - full
    - full
    - full
    kb_pct: 26.1
  - rank: 4
    id: opencode-cli
    name: OpenCode
    score: '94.4'
    build: 1.18.31
    model: muse-spark-1.3
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '15'
      max: 15
      pct: 100.0
      tone: full
    - label: Portability
      abbr: Portable
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Durability
      abbr: Durable
      value: '9.4'
      max: 15
      pct: 62.7
      tone: low
    kb: 235
    session_kb: 35
    content_pct: 15
    copies: '2.8'
    blocks:
    - 100
    - 100
    - 77
    once_pct: 0
    events: 77
    statements: 213
    once: 0
    stamps_pct: 100
    grid:
    - full
    - none
    - full
    - full
    - full
    - full
    - full
    kb_pct: 33.7
  - rank: 5
    id: kimi
    name: Kimi Code
    score: '91.2'
    build: 2.1.1
    model: kimi-k2.7-code
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '12'
      max: 15
      pct: 80.0
      tone: mid
    - label: Portability
      abbr: Portable
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Durability
      abbr: Durable
      value: '9.2'
      max: 15
      pct: 61.3
      tone: low
    kb: 215
    session_kb: 17
    content_pct: 8
    copies: '2.1'
    blocks:
    - 100
    - 100
    - 14
    once_pct: 0
    events: 42
    statements: 90
    once: 0
    stamps_pct: 100
    grid:
    - full
    - none
    - full
    - none
    - full
    - full
    - full
    kb_pct: 30.8
  - rank: 6
    id: claude-cli
    name: Claude Code
    score: '89.3'
    build: 2.1.272
    model: claude-sonnet-5
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '12'
      max: 15
      pct: 80.0
      tone: mid
    - label: Portability
      abbr: Portable
      value: '18'
      max: 20
      pct: 90.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '9.3'
      max: 15
      pct: 62.0
      tone: low
    kb: 113
    session_kb: 26
    content_pct: 23
    copies: '1.2'
    blocks:
    - 100
    - 19
    once_pct: 81
    events: 48
    statements: 57
    once: 39
    stamps_pct: 77
    grid:
    - full
    - part
    - full
    - none
    - full
    - none
    - part
    kb_pct: 16.2
  - rank: 7
    id: openclaw
    name: OpenClaw
    score: '88.1'
    build: 2026.9.8
    model: gpt-5.6-terra
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '12'
      max: 15
      pct: 80.0
      tone: mid
    - label: Portability
      abbr: Portable
      value: '17'
      max: 20
      pct: 85.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '9.1'
      max: 15
      pct: 60.7
      tone: low
    kb: 697
    session_kb: 23
    content_pct: 3
    copies: '3.1'
    blocks:
    - 100
    - 100
    - 100
    - 12
    once_pct: 0
    events: 43
    statements: 134
    once: 0
    stamps_pct: 100
    grid:
    - full
    - none
    - full
    - none
    - full
    - full
    - full
    kb_pct: 100.0
  - rank: 8
    id: codex-cli
    name: Codex
    score: '87.5'
    build: 0.154.0
    model: gpt-5.6-sol
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '15'
      max: 15
      pct: 100.0
      tone: full
    - label: Portability
      abbr: Portable
      value: '15'
      max: 20
      pct: 75.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '7.5'
      max: 15
      pct: 50.0
      tone: low
    kb: 185
    session_kb: 26
    content_pct: 14
    copies: '2.1'
    blocks:
    - 100
    - 100
    - 7
    once_pct: 7
    events: 44
    statements: 91
    once: 3
    stamps_pct: 100
    grid:
    - full
    - part
    - full
    - full
    - full
    - none
    - full
    kb_pct: 26.5
  - rank: 9
    id: hermes
    name: Hermes
    score: '86.4'
    build: 0.21.5
    model: gpt-5.5
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '5.5'
      max: 15
      pct: 36.7
      tone: low
    - label: Portability
      abbr: Portable
      value: '17'
      max: 20
      pct: 85.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '13.9'
      max: 15
      pct: 92.7
      tone: mid
    kb: 36
    session_kb: 23
    content_pct: 64
    copies: '1.0'
    blocks:
    - 100
    once_pct: 100
    events: 40
    statements: 40
    once: 40
    stamps_pct: 100
    grid:
    - full
    - full
    - part
    - none
    - full
    - full
    - full
    kb_pct: 5.2
  - rank: 10
    id: claude-desktop
    name: Claude Desktop
    score: '85.6'
    build: 2.1.270
    model: claude-opus-5
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '28.8'
      max: 30
      pct: 96.0
      tone: mid
    - label: Causality
      abbr: Causal
      value: '18.3'
      max: 20
      pct: 91.5
      tone: mid
    - label: Usage
      abbr: Usage
      value: '12'
      max: 15
      pct: 80.0
      tone: mid
    - label: Portability
      abbr: Portable
      value: '18'
      max: 20
      pct: 90.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '8.6'
      max: 15
      pct: 57.3
      tone: low
    kb: 469
    session_kb: 20
    content_pct: 4
    copies: '1.2'
    blocks:
    - 100
    - 25
    once_pct: 75
    events: 24
    statements: 30
    once: 18
    stamps_pct: 85
    grid:
    - part
    - part
    - full
    - none
    - full
    - none
    - part
    kb_pct: 67.3
  - rank: 11
    id: antigravity
    name: Antigravity
    score: '82.7'
    build: 1.2.17
    model: claude-sonnet-4-6
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '8'
      max: 15
      pct: 53.3
      tone: low
    - label: Portability
      abbr: Portable
      value: '15'
      max: 20
      pct: 75.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '9.7'
      max: 15
      pct: 64.7
      tone: low
    kb: 236
    session_kb: 54
    content_pct: 23
    copies: '2.3'
    blocks:
    - 100
    - 100
    - 34
    once_pct: 0
    events: 56
    statements: 131
    once: 0
    stamps_pct: 100
    grid:
    - full
    - none
    - part
    - none
    - none
    - full
    - full
    kb_pct: 33.9
  - rank: 12
    id: cursor-cli
    name: Cursor CLI
    score: '78.1'
    build: 2026.10.01
    model: cursor-grok-4.5
    cats:
    - label: Fidelity
      abbr: Fidelity
      value: '30'
      max: 30
      pct: 100.0
      tone: full
    - label: Causality
      abbr: Causal
      value: '20'
      max: 20
      pct: 100.0
      tone: full
    - label: Usage
      abbr: Usage
      value: '3'
      max: 15
      pct: 20.0
      tone: low
    - label: Portability
      abbr: Portable
      value: '15'
      max: 20
      pct: 75.0
      tone: mid
    - label: Durability
      abbr: Durable
      value: '10.1'
      max: 15
      pct: 67.3
      tone: low
    kb: 136
    session_kb: 36
    content_pct: 26
    copies: '2.7'
    blocks:
    - 100
    - 100
    - 68
    once_pct: 28
    events: 74
    statements: 198
    once: 21
    stamps_pct: 100
    grid:
    - full
    - part
    - none
    - none
    - none
    - full
    - full
    kb_pct: 19.5
  by_size:
  - pi
  - hermes
  - claude-cli
  - cursor-cli
  - copilot
  - codex-cli
  - deepseek-harness-cli
  - kimi
  - opencode-cli
  - antigravity
  - claude-desktop
  - openclaw
  by_copies:
  - pi
  - hermes
  - claude-cli
  - claude-desktop
  - deepseek-harness-cli
  - copilot
  - codex-cli
  - kimi
  - antigravity
  - cursor-cli
  - opencode-cli
  - openclaw
---

<style>
.sb1 { --sb-full:#0071e3; --sb-mid:#f0a020; --sb-low:#e5484d; --sb-soft:rgba(0,113,227,.20); --sb-track:rgba(0,0,0,.07); }
@media (prefers-color-scheme: dark) {
  .sb1 { --sb-full:#2997ff; --sb-mid:#ffb224; --sb-low:#ff6369; --sb-soft:rgba(41,151,255,.28); --sb-track:rgba(255,255,255,.12); }
}
.sb1-card { background:var(--bg-elev); border:1px solid var(--hair-strong); border-radius:18px; padding:22px 22px 18px; }
.sb1-title { font-size:17px; font-weight:650; letter-spacing:-.01em; color:var(--ink); margin:0; }
.sb1-sub { font-size:13.5px; color:var(--ink-2); margin:3px 0 16px; line-height:1.45; }
.sb1 small { font-weight:400; color:var(--ink-2); }
.sb1-num { font-variant-numeric:tabular-nums; }

/* scorecard */
.sb1-score { display:grid; grid-template-columns:22px minmax(150px,1.5fr) 62px repeat(5,minmax(58px,1fr)); column-gap:0; row-gap:0; align-items:stretch; }
.sb1-score > * { padding:10px 14px 10px 0; border-top:1px solid var(--hair); display:flex; flex-direction:column; justify-content:center; }
.sb1-score > .sb1-meters > * { padding:10px 14px 10px 0; border-top:1px solid var(--hair); display:flex; flex-direction:column; justify-content:center; }
.sb1-score .sb1-h { border-top:0; padding:0 14px 8px 0; display:block; font-size:11.5px; font-weight:600; letter-spacing:.02em; text-transform:uppercase; color:var(--ink-2); }
.sb1-score .sb1-h small { text-transform:none; letter-spacing:0; margin-left:3px; color:var(--ink-3); }
.sb1-rank { font-size:13px; color:var(--ink-3); font-variant-numeric:tabular-nums; }
.sb1-name { font-size:15px; font-weight:600; color:var(--ink); line-height:1.25; }
.sb1-name { min-width:0; }
.sb1-name small { display:block; font-size:11.5px; color:var(--ink-3); margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.sb1-total { font-size:21px; font-weight:700; letter-spacing:-.02em; color:var(--ink); font-variant-numeric:tabular-nums; }
.sb1-meter { display:block; }
.sb1-meter b { display:block; font-size:12px; font-weight:600; color:var(--ink); font-variant-numeric:tabular-nums; margin-bottom:4px; }
.sb1-meter u { display:block; height:7px; border-radius:4px; background:var(--sb-track); overflow:hidden; text-decoration:none; }
.sb1-meter i { display:block; height:100%; border-radius:4px; }
.sb1-meter em { display:none; }
.sb1-full { background:var(--sb-full); } .sb1-mid { background:var(--sb-mid); } .sb1-low { background:var(--sb-low); }
.sb1-legend { display:flex; flex-wrap:wrap; gap:6px 16px; margin-top:14px; font-size:12.5px; color:var(--ink-2); }
.sb1-legend span { display:inline-flex; align-items:center; gap:6px; }
.sb1-legend i { width:18px; height:7px; border-radius:4px; display:inline-block; }
@media (max-width:700px) {
  .sb1-card { padding:16px 14px 14px; border-radius:14px; }
  .sb1-score { grid-template-columns:24px 1fr auto; }
  .sb1-score .sb1-h { display:none; }
  .sb1-score > .sb1-meters { grid-column:1 / -1; }
  .sb1-score > .sb1-meters > * { border-top:0; padding:0; }
  .sb1-meter em { display:block; font-style:normal; font-size:10px; color:var(--ink-3); text-transform:uppercase; letter-spacing:.03em; margin-top:3px; }
}
.sb1-score > .sb1-meters { display:contents; }
@media (max-width:700px) { .sb1-score > .sb1-meters { display:grid; grid-template-columns:repeat(5,1fr); gap:8px; border-top:0; padding:0 0 12px; } }

/* horizontal bar charts */
.sb1-bars { display:grid; grid-template-columns:132px 1fr; column-gap:12px; row-gap:9px; align-items:center; }
.sb1-bars .sb1-lab { font-size:14px; font-weight:550; color:var(--ink); text-align:right; white-space:nowrap; }
.sb1-line { display:flex; align-items:center; gap:10px; min-width:0; position:relative; }
.sb1-bar { display:block; height:20px; border-radius:6px; background:var(--sb-soft); overflow:hidden; flex:0 0 auto; min-width:3px; }
.sb1-bar i { display:block; height:100%; background:var(--sb-full); border-radius:6px 0 0 6px; min-width:2px; }
.sb1-val { font-size:13.5px; font-weight:650; color:var(--ink); white-space:nowrap; font-variant-numeric:tabular-nums; }
.sb1-val small { font-size:12.5px; margin-left:4px; }
.sb1-copies .sb1-line { gap:3px; }
.sb1-block { display:block; height:20px; border-radius:4px; flex:0 0 auto; }
.sb1-copies .sb1-val { margin-left:7px; }
@media (max-width:700px) {
  .sb1-bars { grid-template-columns:max-content 1fr; column-gap:9px; }
  .sb1-block { height:18px; }
  .sb1-bars .sb1-lab { font-size:13px; }
  .sb1-val small { display:block; margin:0; }
}

/* capability grid */
.sb1-scroll { overflow-x:auto; -webkit-overflow-scrolling:touch; margin:0 -6px; padding:0 6px; }
table.sb1-grid { border-collapse:collapse; width:100%; min-width:580px; font-size:13.5px; margin:0; }
table.sb1-grid th, table.sb1-grid td { border:0; border-top:1px solid var(--hair); padding:8px 6px; text-align:center; background:transparent; }
table.sb1-grid thead th { border-top:0; font-size:11.5px; font-weight:600; color:var(--ink-2); line-height:1.25; vertical-align:bottom; padding-bottom:10px; }
table.sb1-grid th:first-child, table.sb1-grid td:first-child { text-align:left; font-weight:600; color:var(--ink); white-space:nowrap; position:sticky; left:0; background:var(--bg-elev); }
.sb1-dot { display:inline-block; width:15px; height:15px; border-radius:50%; vertical-align:middle; box-sizing:border-box; }
.sb1-dot-full { background:var(--sb-full); }
.sb1-dot-part { border:2px solid var(--sb-mid); background:linear-gradient(90deg, var(--sb-mid) 50%, transparent 50%); }
.sb1-dot-none { border:2px solid var(--ink-3); opacity:.55; }
.sb1-sr { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; }

/* small cards */
.sb1-steps, .sb1-picks { display:grid; gap:12px; margin:22px 0; }
.sb1-steps { grid-template-columns:repeat(auto-fit,minmax(168px,1fr)); }
.sb1-picks { grid-template-columns:repeat(auto-fit,minmax(250px,1fr)); }
.sb1-step, .sb1-pick { background:var(--bg-elev); border:1px solid var(--hair-strong); border-radius:14px; padding:14px 16px; }
.sb1-step b { display:block; font-size:12px; letter-spacing:.04em; text-transform:uppercase; color:var(--sb-full); margin-bottom:4px; }
.sb1-step span, .sb1-pick span { font-size:14.5px; line-height:1.45; color:var(--ink); }
.sb1-pick b { display:block; font-size:15.5px; font-weight:650; color:var(--ink); margin-bottom:5px; }
.sb1-pick span { color:var(--ink-2); }
.sb1-pick span strong { color:var(--ink); font-weight:600; }
.sb1-tl { background:var(--bg-sunken); border-radius:14px; padding:16px 18px; margin:22px 0; }
.sb1-tl ul { margin:0; padding-left:20px; }
.sb1-tl li { margin:5px 0; }
</style>

We ran the same two-prompt bug fix through twelve coding-agent harnesses,
three times each, and kept only the session files they wrote. The file being
fixed is 223 bytes long. Pi recorded the whole session in 19 KB. OpenClaw
recorded it in 697 KB, and 3% of that is the session.

Size is the cheap finding. The one that matters is what you can get back.
For every run we rebuilt the session from its files alone and checked 31
facts against an independent record of what happened: both prompts and
replies, every tool call with its result and exit code, the file before and
after the edit, the model, the token counts, the timestamps, and whether the
files open at all without the vendor's own code. That is
**[Session-Bench v1]({{ '/bench/v1/' | relative_url }})**: 100 points, twelve
harnesses, 36 runs, and every score recomputes from the published session
files with one command per run.

[The August bench]({{ '/blog/session-bench-launch/' | relative_url }}) asked
twenty pass/fail questions of each format, answered mostly from our own corpus
and weekly drift checks. v1 is a different instrument. It runs the harness,
keeps an outside witness, and replays the result. The two do not share a
scale, and the order changed.

<figure class="post-figure sb1" id="scorecard">
<div class="sb1-card">
<p class="sb1-title">Session-Bench v1: twelve harnesses, the same two-prompt fix</p>
<p class="sb1-sub">Points out of 100, mean of three runs. Blue is full marks in a category; amber and red show where the points go.</p>
<div class="sb1-score">
<span class="sb1-h"></span><span class="sb1-h">Harness</span><span class="sb1-h">Score</span><span class="sb1-h">Fidelity<small>30</small></span><span class="sb1-h">Causality<small>20</small></span><span class="sb1-h">Usage<small>15</small></span><span class="sb1-h">Portable<small>20</small></span><span class="sb1-h">Durable<small>15</small></span>
{% for a in page.bench.agents %}<span class="sb1-rank">{{ a.rank }}</span><span class="sb1-name">{{ a.name }}<small>{{ a.build }} · {{ a.model }}</small></span><span class="sb1-total">{{ a.score }}</span><span class="sb1-meters">{% for c in a.cats %}<span class="sb1-meter" title="{{ c.label }}: {{ c.value }} of {{ c.max }}"><b>{{ c.value }}</b><u><i class="sb1-{{ c.tone }}" style="width:{{ c.pct }}%"></i></u><em>{{ c.abbr }}</em></span>{% endfor %}</span>
{% endfor %}</div>
<div class="sb1-legend"><span><i class="sb1-full"></i>full marks</span><span><i class="sb1-mid"></i>70% or more of the category</span><span><i class="sb1-low"></i>below 70%</span></div>
</div>
<figcaption>Every score recomputes from the published session files. Version and model are the ones in the test: the harnesses did not run the same model, and the model is not what is graded. Full version strings and the document behind each row are on <a href="{{ '/bench/v1/' | relative_url }}">the bench page</a>.</figcaption>
</figure>

<div class="sb1 sb1-tl" markdown="1">

**The short version**

- All twelve keep the conversation. Prompts, replies, tool calls and results
  come back in every run, with one partial exception.
- The spread is 78 to 97, and it comes from storage, not memory: how many
  times each event is written, whether the cost is recorded, and how much of
  the file is the session at all.
- Pi and Hermes write each event once. Four harnesses never do.
- Four of twelve record token usage that adds up to a stated total. One
  records none.
- DeepSeek Harness is first at 96.9, Cursor CLI last at 78.1. The model
  inside is not what is graded: the twelve rows did not run the same one.

</div>

## How a run is scored

<div class="sb1 sb1-steps">
<div class="sb1-step"><b>1 · Same task</b><span>Two prompts against a small Python project: run a check that fails, then take a correction, edit one file and run the check again. Four tool calls are scored.</span></div>
<div class="sb1-step"><b>2 · An outside witness</b><span>The harness's live output stream where it has one, a ledger that the check script writes each time it runs, and hashes of the project files record what really happened. None of it comes from the session files.</span></div>
<div class="sb1-step"><b>3 · Files only</b><span>A decoder reads the session files the harness left on disk, and nothing else.</span></div>
<div class="sb1-step"><b>4 · 31 comparisons</b><span>Each fact in the files is matched to the witness. Missing scores zero. Wrong scores zero. Present but unreadable scores zero.</span></div>
</div>

The 31 metrics add up to 100 points in five groups: record fidelity (30),
causality and context (20), usage and attribution (15), portability and
openness (20), durability and signal (15). Each harness gets the mean of
three runs.

## Everyone keeps the conversation

The least surprising result is the one that matters most if you worry about
losing work. Eleven of twelve harnesses score 30 of 30 on record fidelity and
20 of 20 on causality in every run: both prompts, both replies, all four tool
calls, their results and exit codes, which edit followed which correction, and
which result belongs to which call. Claude Desktop is the exception, and the cause is
the run rather than the format: its model wrote the file from inside a shell
command instead of calling an edit tool, so the edit has no result of its own
to match, and one result in four goes missing.

So if the chat window loses a session, the file still has it.
[Where each agent keeps those files]({{ '/blog/where-agents-store-history/' | relative_url }})
and [how to get a lost session back]({{ '/blog/recovering-a-lost-session/' | relative_url }})
are earlier posts. The 19 points between first place and last come from
everything else.

## The same fix, 19 KB to 697 KB

<figure class="post-figure sb1" id="bytes">
<div class="sb1-card">
<p class="sb1-title">Bytes on disk for the same fix</p>
<p class="sb1-sub">Everything the harness stored for the session, mean of three runs. The solid part is the session itself: prompts, replies, tool calls and results.</p>
<div class="sb1-bars">
{% for id in page.bench.by_size %}{% assign a = page.bench.agents | where: "id", id | first %}<span class="sb1-lab">{{ a.name }}</span><span class="sb1-line"><span class="sb1-bar" style="width:{{ a.kb_pct | times: 0.62 }}%" title="{{ a.session_kb }} KB of {{ a.kb }} KB is the session"><i style="width:{{ a.content_pct }}%"></i></span><span class="sb1-val">{{ a.kb }} KB<small>{{ a.content_pct }}% session</small></span></span>
{% endfor %}</div>
</div>
<figcaption>KB is 1,000 bytes. Where sessions live in a shared database, the total counts the rows of this session. OpenClaw ran on its Codex backend, whose files for the session are 72% of its total.</figcaption>
</figure>

The session itself is small everywhere: between 15 KB and 108 KB of prompts,
replies, tool calls and results. What varies by a factor of 37 is the total.
The rest is what the harness writes around the session: its instructions and
tool definitions, repeated copies, snapshots and bookkeeping.

This is not a disk-space problem. It is a context problem. The moment you
paste a raw session file into another model, to summarize it, to hand the
work to a different agent, or to ask what went wrong, you pay for every byte.
At a rough four bytes per token, Pi's record is under 5,000 tokens. Claude
Desktop's is about 117,000 and OpenClaw's about 174,000, for the same
two-prompt fix. [Handover between sessions]({{ '/blog/the-handover-problem/' | relative_url }})
is hard enough without paying 35 times over for the transcript.

One caveat on the longest bar. OpenClaw ran on its Codex backend in our setup,
and 72% of its 697 KB is that backend's own files for the session, written in
a home the plugin owns. They land on your disk for the same work, so they
count. OpenClaw's own store is about 190 KB.

## How many times it says each thing

<figure class="post-figure sb1" id="copies">
<div class="sb1-card">
<p class="sb1-title">How many times each event is written</p>
<p class="sb1-sub">Stored statements per event, read top to bottom with no knowledge of the format. One block is one copy.</p>
<div class="sb1-bars sb1-copies">
{% for id in page.bench.by_copies %}{% assign a = page.bench.agents | where: "id", id | first %}<span class="sb1-lab">{{ a.name }}</span><span class="sb1-line">{% for b in a.blocks %}<i class="sb1-block {% if a.once_pct == 100 %}sb1-full{% elsif a.once_pct == 0 %}sb1-low{% else %}sb1-mid{% endif %}" style="flex-basis:{{ b | times: 0.17 }}%"></i>{% endfor %}<span class="sb1-val">{{ a.copies }}×<small>{% if a.once_pct == 100 %}every event once{% elsif a.once_pct == 0 %}no event only once{% else %}{{ a.once_pct }}% of events once{% endif %}</small></span></span>
{% endfor %}</div>
</div>
<figcaption>Counted on the records a reader has to open to recover the session. Blue: every event appears exactly once. Amber: some do. Red: none does.</figcaption>
</figure>

Read a session top to bottom the way a script or a model would, with no
knowledge of the format, and count how often each prompt, reply, tool call and
result is stated. Pi and Hermes state each one once. OpenCode, Kimi Code,
OpenClaw and Antigravity never do: every event appears at least twice, and no
field marks the later copies as copies. Codex stores 3 of 44 events once across its three runs.

The causes differ. OpenCode writes every message part again, one to five
times, into an `event` table as the part updates. Kimi Code's wire log states
each prompt three times and each reply, tool call and result twice: once as it
happens and once more in a summary record when the turn ends. Codex logs each
prompt, reply, command, result and edit twice, as a UI event and as the wire
item. OpenClaw stores each tool call in two forms and repeats the events in a
trace table. Claude Code writes each prompt twice and repeats an edit's
arguments in its result.

Two things follow. A tool that counts messages or tool calls straight from the
file over-counts by the factor in the chart. And a model that reads the raw
file reads the same command output two or three times, which is the previous
chart again.

## What did it cost

Nine of twelve write token counts with separate input, output, cache-read and
cache-write numbers. Four of the nine also write a total that the per-reply
records add up to: DeepSeek Harness, Copilot CLI, OpenCode and Codex. Those
are the rows where you can check the arithmetic from the files alone.

The other five have numbers and nothing to check them against. Pi's six
per-message records add up exactly, but the file states no total, and Kimi
Code, Claude Code and Claude Desktop are in the same position. OpenClaw's own
store writes the token total of a run, twice, and no per-request numbers.

Then the three with gaps. Hermes keeps session totals and the usage record of
the last request only, so one of the two replies has numbers of its own.
Antigravity records input, output and cache-read counts and has no cache-write
field. Cursor CLI stores no token count of any kind in the session.

If you want to know what a feature cost you, that is the buying guide.

## What you can get back, row by row

<figure class="post-figure sb1" id="grid">
<div class="sb1-card">
<p class="sb1-title">What you can get back from the files</p>
<p class="sb1-sub">Filled: yes in all three runs. Half: partly. Ring: no.</p>
<div class="sb1-scroll">
<table class="sb1-grid">
<thead><tr><th>Harness</th><th>Whole<br>conversation</th><th>Each event<br>once</th><th>Token<br>counts</th><th>A total<br>to check</th><th>Opens with<br>standard tools</th><th>States its<br>format version</th><th>Time on<br>every event</th></tr></thead>
<tbody>
{% for a in page.bench.agents %}<tr><td>{{ a.name }}</td>{% for g in a.grid %}<td><i class="sb1-dot sb1-dot-{{ g }}"></i><span class="sb1-sr">{% if g == "full" %}yes{% elsif g == "part" %}partly{% else %}no{% endif %}</span></td>{% endfor %}</tr>
{% endfor %}</tbody>
</table>
</div>
</div>
<figcaption>From the 31 metrics. "A total to check" means the token counts of the replies add up to a total that the files state. OpenClaw's counts are per run, not per request.</figcaption>
</figure>

**DeepSeek Harness, 96.9.** A Zstandard-compressed JSONL file per session
with a declared format version, usage on every step that adds up to a stated
total, and timestamps on 12 of 13 events. It loses its points on repetition:
each prompt and each tool call is written twice, so 63% of events appear once.
It also keeps the most actual session of the twelve, 108 KB.

**Pi, 96.4.** One plain `session.jsonl`. 19 KB, every event written once, 79%
of the bytes are the session. It records usage and cost per message and states
no total, which is the 3 points it drops. The smallest record in the set is
also the cleanest, as it was in August.

**Copilot CLI, 96.0.** An event log per session plus a SQLite store that holds
one usage row per model call. The shutdown event states cumulative totals and
the rows add up to them in every run. The same store keeps second copies of
prompts and replies, so 43% of events appear once.

**OpenCode, 94.4.** One SQLite database that `sqlite3` reads without help,
usage that adds up, a migration ledger that serves as a version. Then the
`event` table: no event is stored only once, and 15% of 235 KB is the session.

**Kimi Code, 91.2.** A wire log that keeps everything, including the requests
it had to retry after a rate limit. Prompts three times, replies and results
twice, and 8% of 215 KB is the session. It writes an exit code only when a
command fails. Usage on every request, no total.

**Claude Code, 89.3.** One JSONL transcript per session, 81% of events once,
usage on every reply. It writes no format version of any kind, and 10 of 13
events carry a usable timestamp.

**OpenClaw, 88.1.** Its own SQLite stores plus the files of the backend it
ran on: 697 KB, 3% session, 3.1 copies of each event. Events above a size
limit are Zstandard-compressed inside the database, the first prompt among
them. Usage is a run total.

**Codex, 87.5.** One rollout JSONL per session with complete usage that adds
up. Everything in it is written twice: 3 of 44 events appear once across the
three runs, and 14% of the bytes are the session. No storage format version. Codex Desktop writes the
same format and shares the row.

**Hermes, 86.4.** Rows in one SQLite database: 36 KB, each event once, 64%
session, a schema version. It is the second-leanest record here, and it scores
5.5 of 15 on usage because it keeps the numbers of one request only.

**Claude Desktop, 85.6.** The Claude Code transcript format plus a metadata
file, at four times the bytes: 469 KB, 4% session. The transcript embeds your
instruction files, skill list and connector instructions along with the work.

**Antigravity, 82.7.** A SQLite database per conversation whose columns hold
protobuf messages with no published schema. Standard tools open the database
and cannot read the session. No event is stored only once.

**Cursor CLI, 78.1.** The whole conversation is a graph of content-addressed
blobs in a SQLite file: JSON messages and protobuf records with no published
schema. No token count of any kind, and 2.7 copies of each event.

## Using this if you build with agents every day

<div class="sb1 sb1-picks">
<div class="sb1-pick"><b>You want to know what a feature cost</b><span><strong>DeepSeek Harness, Copilot CLI, OpenCode and Codex</strong> write token counts per reply and a total they add up to. Pi adds a cost figure per message. With Cursor CLI the session file cannot tell you.</span></div>
<div class="sb1-pick"><b>You paste sessions into another model</b><span><strong>Pi and Hermes</strong> give you each event once and little else. For Claude Desktop, OpenClaw, Kimi Code and OpenCode the raw file is mostly not your session: export or filter before you paste.</span></div>
<div class="sb1-pick"><b>You script over your history</b><span>Expect repeats everywhere except Pi and Hermes, and de-duplicate by id. Check for a format version before you parse: <strong>Claude Code, Claude Desktop and Codex</strong> write none.</span></div>
<div class="sb1-pick"><b>You want to read it with what you have</b><span><code>jq</code> or <code>sqlite3</code> is enough for ten of the twelve, with <code>zstd</code> for DeepSeek Harness and OpenClaw. <strong>Antigravity and Cursor CLI</strong> store protobuf, so you need a decoder.</span></div>
<div class="sb1-pick"><b>You attach a session to a bug report</b><span>A raw session file carries your home path and often account ids, your instruction files and hashes of local paths. Read the next section first.</span></div>
<div class="sb1-pick"><b>You only need the transcript</b><span>Any of the twelve. That part works.</span></div>
</div>

## What we got wrong on the way

The August post had a section like this one, and a bench that grades other
people's records has to keep its own.

**OpenCode was first, then it was fourth.** Our first scoring read OpenCode's
`event` table, and duplicate safety came out at zero. We then switched to a
leaner reading that left the table out. That was worth exactly 3 points and
put OpenCode first at 97.4. An outside review caught it: the rubric fixes what
the reader opens before any score is computed. We put the first reading back.
OpenCode is at 94.4.

**OpenClaw had 3 points it had not earned.** We credited its token total as
adding up. The store writes one run total twice and no per-request numbers, so
there is nothing to add. The credit is gone.

**We replaced failed runs, against our own rule.** The rubric says a scheduled
run is not replaced. For OpenClaw, Claude Desktop and Kimi Code we replaced
attempts that died on a controller fault, a provider rate limit or a missing
reply marker. None of them had a score. We kept the rows, waived the rule for
v1, and say so in the report.

**Our published evidence leaked, more than once.** Session files carry more
of your machine than you would guess. Reviewers found, in files we had already
cleaned: a cache file named by a hash of an account id, an index keyed by a
hash of a private temp path, a fingerprint of a home folder listing, and a
local date that gave away the time zone. All of it is fixed, and the report
lists what still stays readable. If you are about to attach a raw session file
to a public issue, that list is for you.

Four rounds of outside review went into this release. The first three said
do not ship.

## What this does not show

One small synthetic task: two prompts, four tool calls, three runs per harness,
one machine. Nothing here covers long sessions, compaction, sub-agents,
crashes or resumes, which is where session formats get tested in real work.

Each harness ran at one version with one model, and not the same model
across rows, so this is not a model comparison and a later version can score
differently.
Some scoring rules were written after the first captures. The repeat count
depends on which stores a reader has to open, which favors formats that keep
everything in one lean file.

Five rows (OpenClaw, Codex, Hermes, Antigravity and Cursor CLI) keep part of a
session in stores shared with other sessions. We do not read other sessions'
data, so their root could not be verified as complete, and that costs each of
them 3 portability points.

The checker compares the path and id of an edit, not its text. Packet reviews
were done by separate AI agent sessions on the same machine, with the outside
model reviews on top; no second person repeated the captures. Cursor Desktop
is not scored yet.

## Replay it

Every score can be recomputed. The release holds the sanitized session files
of all 36 runs, the scoring source, and one command per run that replays the
31 metrics from those files.

- [The bench page]({{ '/bench/v1/' | relative_url }}): the table, the waivers and the limits
- [The report](https://github.com/jazzyalex/session-bench/blob/main/artifacts/survival-v1-release/REPORT.md)
- [Replay instructions](https://github.com/jazzyalex/session-bench/blob/main/artifacts/survival-v1-release/REPRODUCE.md)
- [The rubric](https://github.com/jazzyalex/session-bench/blob/main/docs/survival-v1/rubric.md) and
  [how each row was decided](https://github.com/jazzyalex/session-bench/tree/main/docs/survival-v1/adapters),
  with every judgment call and what it is worth

If you think a row is wrong, its document lists the judgment calls and their
point values. Dispute one and the score follows. Session-Bench lives in its
own repository, [github.com/jazzyalex/session-bench](https://github.com/jazzyalex/session-bench),
and disputes are welcome there as issues.
[Agent Sessions](https://jazzyalex.github.io/agent-sessions/?campaign=blog&ref=session-bench-v1)
is a free, local-only macOS browser for these session stores; reading them
every day is how the bench got built.
