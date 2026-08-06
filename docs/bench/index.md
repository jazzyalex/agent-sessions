---
layout: blog
title: "Session Bench — the coding-agent session-format benchmark"
description: "A pass/fail benchmark of the session records coding agents write to disk: signal density, completeness, stability, openness, and tooling cost, measured across ten harnesses."
permalink: /bench/
---
<p class="eyebrow">Agent Sessions</p>
<h1>Session Bench</h1>
<p class="lede">A benchmark of coding-agent <em>session formats</em> — the
durable work record each harness writes to disk. Nineteen scored pass/fail
gates across five areas, each backed by a measurement, a fixture, or a
monitoring-ledger entry. No partial credit: a gate is pass, fail, or
explicitly <em>not run</em> — never averaged.</p>

<p class="post-meta">Bench v{{ site.data.session_bench.version }} ·
data measured {{ site.data.session_bench.data_date }} ·
surface: {{ site.data.session_bench.surface }} ·
<a href="{{ site.data.session_bench.methodology_url }}">measurements, checklist &amp; evaluator</a></p>

<style>
.bench-table { width:100%; border-collapse:collapse; margin:1.5rem 0; font-size:0.92rem; }
.bench-table th, .bench-table td { padding:0.5rem 0.55rem; border-bottom:1px solid var(--rule, #e1e0d9); text-align:left; }
.bench-table th { font-weight:600; }
.bench-table td.num, .bench-table th.num { text-align:right; font-variant-numeric:tabular-nums; }
.bench-rank { color:var(--muted, #898781); }
.bench-note { color:var(--muted, #898781); font-size:0.85em; }
.bench-matrix { overflow-x:auto; }
.bench-matrix table { border-collapse:collapse; font-size:0.85rem; min-width:640px; }
.bench-matrix th, .bench-matrix td { padding:0.35rem 0.5rem; border-bottom:1px solid var(--rule, #e1e0d9); text-align:center; }
.bench-matrix th:first-child, .bench-matrix td:first-child { text-align:left; white-space:nowrap; }
.bench-pass { color:#1a7f37; font-weight:600; }
.bench-fail { color:#b42318; font-weight:600; }
.bench-na { color:var(--muted, #898781); }
@media (prefers-color-scheme: dark) {
  .bench-table th, .bench-table td, .bench-matrix th, .bench-matrix td { border-bottom-color:#2c2c2a; }
  .bench-pass { color:#3fb950; }
  .bench-fail { color:#f85149; }
}
</style>

## Leaderboard

<table class="bench-table">
  <thead>
    <tr>
      <th class="bench-rank">#</th><th>Harness</th><th>Version</th><th>Format</th>
      <th class="num">Signal</th><th class="num">Complete</th><th class="num">Stable</th><th class="num">Open</th><th class="num">Tooling</th>
      <th class="num">Cleared</th>
    </tr>
  </thead>
  <tbody>
    {% for agent in site.data.session_bench.agents %}
    <tr>
      <td class="bench-rank">{{ agent.rank }}{% if agent.provisional %}<span title="provisional: rank {{ agent.rank_best }} at best, {{ agent.rank_worst }} at worst, pending the not-run gate">†</span>{% endif %}</td>
      <td><strong>{{ agent.name }}</strong></td>
      <td class="bench-note">{{ agent.version }}</td>
      <td>{{ agent.format }}</td>
      <td class="num">{{ agent.area_scores.Signal }}</td>
      <td class="num">{{ agent.area_scores.Completeness }}</td>
      <td class="num">{{ agent.area_scores.Stability }}</td>
      <td class="num">{{ agent.area_scores.Openness }}</td>
      <td class="num">{{ agent.area_scores.Tooling }}</td>
      <td class="num"><strong>{{ agent.cleared }}</strong> / {{ agent.scored }}{% if agent.not_run > 0 %} <span class="bench-note">({{ agent.not_run }} not run)</span>{% endif %}</td>
    </tr>
    {% endfor %}
  </tbody>
</table>

<p class="bench-note">Ranking is by fraction of scored gates cleared; ties
share a rank. A gate whose measurement could not be taken for a harness is
marked <em>not run</em> and drops out of that harness's denominator — an
authentication failure is not evidence about a format. Ranks marked †
are provisional: hover for the best/worst range pending the missing
measurement. Every gate carries equal weight within the composite; the
per-area columns are there so you can re-weight by eye. One gate (crash
tolerance) is defined but unscored in v1 pending a real cross-harness
truncation experiment.</p>

Each area answers one question a developer actually has:

- **Signal** — is the log your work, or the harness's paperwork?
- **Completeness** — can you audit what happened and what it cost?
- **Stability** — will your archive still parse after the next update?
- **Openness** — can you read your own history with tools you already have?
- **Tooling** — will scripts and history browsers survive its quirks?

## If you're choosing a harness

The composite rewards all-round formats. If one property matters more to
you, the gate data narrows it fast:

| You need | Best on the bench today | Basis |
|---|---|---|
| Local cost auditing, in dollars | Pi, OpenClaw, OpenCode, Hermes | gate C4 |
| History you can grep and `tail -f` | Pi, OpenClaw, Claude Code, Codex, Kimi | gates O1+O2 |
| Reasoning you can read later | Pi, OpenCode, Hermes, Copilot, Kimi | gate C6 |
| A format that hasn't shifted in 4 months | Pi, OpenClaw, Claude Code, Codex, Cursor, Kimi | gates T1+O4 |
| Search built into the store | Hermes | observed*, not a gate |
| Bit-faithful wire replay | Codex | observed*, not a gate |
| To avoid: history you can't read back | Cursor Agent (binary metadata DB) | gates O1, O2, P3 |

<p class="bench-note">* Editorial observations from the measurement work,
noted because they're decision-relevant; they carry no points.</p>

## The gate matrix

✓ pass · ✗ fail · — not run · ◦ unscored. Hover a cell for the evidence
behind it.

<div class="bench-matrix">
<table>
  <thead>
    <tr>
      <th>Gate</th>
      {% for agent in site.data.session_bench.agents %}<th>{{ agent.short | default: agent.name }}</th>{% endfor %}
    </tr>
  </thead>
  <tbody>
    {% assign areas = "Signal,Completeness,Stability,Openness,Tooling" | split: "," %}
    {% for area in areas %}
    <tr><td colspan="{{ site.data.session_bench.agents | size | plus: 1 }}" style="text-align:left;font-weight:600;padding-top:0.9rem;">{{ area }}</td></tr>
    {% for gate in site.data.session_bench.gates %}
    {% if gate.area == area %}
    <tr>
      <td title="{{ gate.desc }}">{{ gate.id }} — {{ gate.name }}</td>
      {% for agent in site.data.session_bench.agents %}
      {% assign r = agent.results[gate.id] %}
      {% assign note = agent.notes[gate.id] %}
      {% if r == "pass" %}
      <td class="bench-pass" title="{{ note | default: gate.desc }}">✓</td>
      {% elsif r == "fail" %}
      <td class="bench-fail" title="{{ note | default: gate.desc }}">✗</td>
      {% elsif r == "not_run" %}
      <td class="bench-na" title="{{ note | default: gate.desc }}">—</td>
      {% else %}
      <td class="bench-na" title="{{ note | default: gate.desc }}">◦</td>
      {% endif %}
      {% endfor %}
    </tr>
    {% endif %}
    {% endfor %}
    {% endfor %}
  </tbody>
</table>
</div>

## The gates

{% for gate in site.data.session_bench.gates %}
- **{{ gate.id }} — {{ gate.name }}** ({{ gate.area }}): {{ gate.desc }}
{% endfor %}

## Method

What this is, stated precisely: a versioned, evidence-backed comparison
with mechanically generated scores. A measurements manifest (probe results
and corpus statistics) plus an evidence checklist feed `evaluate.py`, which
computes the Signal gates from fixed thresholds, merges the checklist
verdicts, and emits the data file this page renders; `measure.py`
recomputes per-artifact numbers from a session file. Re-running the
evaluator reproduces the scoring from the versioned inputs; reproducing the
observations end-to-end — harness execution to raw artifacts to extraction —
is the v2 milestone, and until it lands this page does not claim to be a
push-button-reproducible benchmark. All inputs live in the
[repo]({{ site.data.session_bench.methodology_url }}); to dispute a score,
dispute a measurement or an evidence line and re-run the evaluator.

The probe is one identical prompt — "{{ site.data.session_bench.probe_prompt }}" —
attempted through each harness's {{ site.data.session_bench.surface }};
where it produced a session, the artifact was measured byte-for-byte, and
where it could not run, the affected gate says so. Desktop apps and IDE surfaces may use different
stores; v1 scores the CLI session store only, and says so. Completeness,
Openness, and Tooling verdicts are checklist items evaluated against real
session files, the sanitized fixtures in the Agent Sessions repo, and the
parsers that read all ten formats in production. Stability comes from a
ledger that has fingerprinted every format's schema roughly weekly since
2026-03-31.

Grades can change. Formats drift — four of ten had a structural break in
the last four months — and the bench re-scores when they do. The bench
version and data date above say exactly what was measured when. Disputes
and corrections are welcome as
[issues](https://github.com/jazzyalex/agent-sessions/issues).

<p class="post-back"><a href="{{ '/blog/' | relative_url }}">&larr; The Rollout</a></p>
