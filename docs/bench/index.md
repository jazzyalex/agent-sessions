---
layout: blog
title: "Session Bench — the coding-agent session-format benchmark"
description: "A pass/fail benchmark of the session records coding agents write to disk: signal density, completeness, stability, openness, and tooling cost, measured across ten harnesses."
permalink: /bench/
image: /assets/bench-social-card.png
---
<p class="eyebrow">Agent Sessions</p>
<h1>Session Bench</h1>
<p class="lede">A benchmark of coding-agent <em>session formats</em> — the
durable work record each harness writes to disk. Nineteen scored pass/fail
gates across five areas, each backed by a measurement, a fixture, or a
monitoring-ledger entry. No partial credit: a gate is pass, fail, or
explicitly <em>not run</em> — never averaged.</p>

<p class="post-meta">Bench v{{ site.data.session_bench.version }} ·
probe {{ site.data.session_bench.dates.probe }} ·
store queries {{ site.data.session_bench.dates.store_queries }} ·
docs review {{ site.data.session_bench.dates.docs_review }} ·
last corrected {{ site.data.session_bench.dates.last_corrected }} ·
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
authentication failure is not evidence about a format, and an observation
window too short to judge stability (Kimi, onboarded 2026-07-25) is not
evidence of stability. Ranks marked †
are provisional: hover for the best/worst range pending the missing
measurement. Every gate carries equal weight within the composite; the
per-area columns are there so you can re-weight by eye. One gate (crash
tolerance) is defined but unscored pending a real cross-harness
truncation experiment.</p>

Each area answers one question a developer actually has:

- **Signal** — is the log your work, or the harness's paperwork?
- **Completeness** — can you audit what happened and what it cost?
- **Stability** — will your archive still parse after the next update?
- **Openness** — can you read your own history with tools you already have?
- **Tooling** — will scripts and history browsers survive its quirks?

## If you're choosing a harness

The composite rewards all-round formats. If one property matters more to
you, the gate data narrows it fast. These rows are generated from the
matrix by the evaluator, so they can never disagree with it:

<table class="bench-table">
  <thead><tr><th>You need</th><th>Qualifies today</th><th>Basis</th></tr></thead>
  <tbody>
  {% for pick in site.data.session_bench.picks %}
  <tr><td>{{ pick.need }}</td><td>{{ pick.who | join: ", " }}</td><td class="bench-note">{{ pick.basis }}</td></tr>
  {% endfor %}
  </tbody>
</table>

Two editorial observations from the measurement work, decision-relevant but
carrying no points: Hermes is the only store with built-in full-text
search, and Codex keeps the most complete wire-replay record. And one
caution from the gates: Cursor's transcript is readable JSONL, but full
reconstruction — model, timestamps, metadata — requires its opaque binary
sidecar (gates O1, O2, P3).

## The gate matrix

✓ pass · ✗ fail · — not run · ◦ unscored · · not applicable. Hover a cell for the evidence
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
      {% elsif r == "not_applicable" %}
      <td class="bench-na" title="{{ note | default: gate.desc }}">·</td>
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

## Corrections

- **2026-08-12 — O3 (documented schema) was originally scored fail for all
  ten harnesses. That was wrong.** An external re-check found real vendor
  documentation that our search missed: Pi publishes a full
  [session-format spec](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)
  (in its tree since April 2026), OpenClaw documents its
  [session store schema and transcript event structure](https://github.com/openclaw/openclaw/blob/main/docs/reference/session-management-compaction.md),
  Hermes documents its
  [persistence layers and stored fields](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/sessions.md),
  and Copilot documents its
  [storage layout](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
  and persisted event types. Four cells flipped: Pi 17→18/19,
  OpenClaw 16→17/18, Copilot 11→12/19, Hermes 10→11/18. Kimi documents its
  session directory layout but not the wire-record schema, so its fail
  stands, as do Claude Code, Codex, Antigravity, and Cursor (nothing
  published) and OpenCode (table definitions in source, not documentation).

- **2026-08-12 (second correction, same review cycle) — v0.1 → v0.2.**
  Codex was underscored by two gates: real rollouts carry plaintext
  `summary_text` on ~35% of reasoning items (C6 passes — the gate accepts a
  stored summary) and `parent_thread_id` + `sub_agent_activity` records
  (C7 passes); Codex moves 12/19 → 14/19, tying Claude Code at rank 3.
  Antigravity's P1 flips to pass — XML-wrapped content is awkward, not
  message loss. Two rubric fixes make this v0.2: T3 is now scored only
  when T2 passes (v0.1 wrongly awarded "honest version" points to
  harnesses with no version at all), and T1 states each harness's actual
  observation window — Kimi's ~10 days is too short to establish stability
  and is now not-run. Denominators shifted accordingly.

- **2026-08-12 (third correction) — v0.2 → v0.3: T2 tightened to format
  versions only.** v0.2 still awarded "declares a version" to harnesses
  that stamp an application/CLI version — the original defect restated.
  T2 now requires a schema/protocol version an external reader can
  dispatch on: Pi (`version` 1-3, documented), OpenClaw (`version` 3), and
  Kimi (`protocol_version`) keep the point; Claude Code, Codex, Copilot,
  and OpenCode lose it (their stamps identify the writer, not the format),
  and their T3 becomes not-applicable. Claude and Codex 14→12/18,
  OpenCode 13→11/17, Copilot 12→10/18. The Codex C6/C7 evidence now cites
  a pinned artifact set with hashes
  ([receipt](https://github.com/jazzyalex/agent-sessions/blob/main/scripts/session_bench/receipts-2026-08-12-codex-c6c7.md)).

## Method

What this is, stated precisely: scores are mechanically generated from
published measurements and checklist verdicts; some underlying raw
artifacts (probe session files, corpus query transcripts) are not yet
public. A measurements manifest plus an evidence checklist feed
`evaluate.py`, which computes the Signal gates from fixed thresholds,
merges the checklist verdicts, and emits the data file this page renders;
`measure.py` recomputes per-artifact numbers from a session file.
Re-running the evaluator reproduces the scoring from the versioned inputs;
reproducing the observations end-to-end — harness execution to archived
raw artifacts to extraction — is the 1.0 milestone, and until it lands
this page does not claim to be a push-button-reproducible benchmark. All inputs live in the
[repo]({{ site.data.session_bench.methodology_url }}); to dispute a score,
dispute a measurement or an evidence line and re-run the evaluator.

The probe is one identical prompt — "{{ site.data.session_bench.probe_prompt }}" —
attempted through each harness's {{ site.data.session_bench.surface }};
where it produced a session, the artifact was measured byte-for-byte, and
where it could not run, the affected gate says so. Desktop apps and IDE surfaces may use different
stores; this bench scores the CLI session store only, and says so. Completeness,
Openness, and Tooling verdicts are checklist items evaluated against real
session files, the sanitized fixtures in the Agent Sessions repo, and the
parsers that read all ten formats in production. Stability comes from a
ledger that has fingerprinted every format's schema roughly weekly since
2026-03-31.

Grades can change, and the version scheme separates the two ways they can:
the **bench version** (currently v{{ site.data.session_bench.version }}) is the rubric — gates, thresholds, scoring
rules — and bumps only when a change breaks score comparability; the
**data date** identifies a re-run under the same rubric. Formats drift —
four of ten had a structural break in the last four months — and the bench
re-scores when they do. v1.0 is reserved for end-to-end reproducibility:
harness execution to archived artifacts to extraction, a tested crash
gate, and per-event classifiers. Disputes
and corrections are welcome as
[issues](https://github.com/jazzyalex/agent-sessions/issues).

<p class="post-back"><a href="{{ '/blog/' | relative_url }}">&larr; The Rollout</a></p>
