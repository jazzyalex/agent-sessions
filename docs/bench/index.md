---
layout: blog
title: "Session Bench — ranking agent harnesses by what they write to disk"
description: "A reproducible pass/fail benchmark of coding-agent session formats: signal density, completeness, stability, openness, and tooling cost, measured across ten harnesses."
permalink: /bench/
---
<p class="eyebrow">Agent Sessions</p>
<h1>Session Bench</h1>
<p class="lede">Ranking agent harnesses by what they write to disk. Twenty
pass/fail gates across five areas — signal, completeness, stability,
openness, tooling cost — each backed by a measurement, a fixture, or a
monitoring-ledger entry. No partial credit.</p>

<p class="post-meta">Bench v{{ site.data.session_bench.version }} ·
data measured {{ site.data.session_bench.data_date }} ·
<a href="{{ site.data.session_bench.methodology_url }}">methodology &amp; scripts</a></p>

<style>
.bench-table { width:100%; border-collapse:collapse; margin:1.5rem 0; font-size:0.95rem; }
.bench-table th, .bench-table td { padding:0.5rem 0.6rem; border-bottom:1px solid var(--rule, #e1e0d9); text-align:left; }
.bench-table th { font-weight:600; }
.bench-table td.num { text-align:right; font-variant-numeric:tabular-nums; }
.bench-rank { color:var(--muted, #898781); }
.bench-matrix { overflow-x:auto; }
.bench-matrix table { border-collapse:collapse; font-size:0.85rem; min-width:640px; }
.bench-matrix th, .bench-matrix td { padding:0.35rem 0.5rem; border-bottom:1px solid var(--rule, #e1e0d9); text-align:center; }
.bench-matrix th:first-child, .bench-matrix td:first-child { text-align:left; white-space:nowrap; }
.bench-pass { color:#1a7f37; font-weight:600; }
.bench-fail { color:#b42318; font-weight:600; }
@media (prefers-color-scheme: dark) {
  .bench-table th, .bench-table td, .bench-matrix th, .bench-matrix td { border-bottom-color:#2c2c2a; }
  .bench-pass { color:#3fb950; }
  .bench-fail { color:#f85149; }
}
</style>

## Leaderboard

<table class="bench-table">
  <thead>
    <tr><th class="bench-rank">#</th><th>Harness</th><th>Format</th><th class="num">Gates cleared</th></tr>
  </thead>
  <tbody>
    {% for agent in site.data.session_bench.agents %}
    {% assign cleared = 0 %}
    {% for gate in site.data.session_bench.gates %}
      {% assign r = agent.results[gate.id] %}
      {% if r == "pass" %}{% assign cleared = cleared | plus: 1 %}{% endif %}
    {% endfor %}
    <tr>
      <td class="bench-rank">{{ forloop.index }}</td>
      <td><strong>{{ agent.name }}</strong></td>
      <td>{{ agent.format }}</td>
      <td class="num"><strong>{{ cleared }}</strong> / {{ site.data.session_bench.gates | size }}</td>
    </tr>
    {% endfor %}
  </tbody>
</table>

## The gate matrix

Hover a cell for the evidence behind it.

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
      {% else %}
      <td class="bench-fail" title="{{ note | default: gate.desc }}">✗</td>
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

One identical prompt is run headless through every harness and the resulting
session artifact is measured byte-for-byte (Signal gates). Completeness,
Openness, and Tooling gates are checklist items evaluated against real
session files, the fixtures in the Agent Sessions repo, and the parsers that
read all ten formats in production. Stability gates come from a monitoring
ledger that has fingerprinted every format's schema roughly weekly since
2026-03-31. A harness whose headless path cannot produce a session fails the
probe gates outright: a run that cannot run is a result.

Grades can change. Formats drift — four of ten had a structural break in the
last four months — and the bench re-scores when they do. The bench version
and data date above say exactly what was measured when. Scripts, fixtures,
and the drift ledger are in the
[Agent Sessions repo](https://github.com/jazzyalex/agent-sessions); disputes
and corrections are welcome as issues.

<p class="post-back"><a href="{{ '/blog/' | relative_url }}">&larr; The Rollout</a></p>
