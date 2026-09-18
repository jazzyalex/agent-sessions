# Prompt: evaluate DeepSeek Harness support and write the implementation plan

You are preparing an implementation plan for Agent Sessions support of DeepSeek
Harness sessions. This is a planning-only task. Do not write Swift, edit the
Xcode project, add fixtures, modify source code, commit, push, or publish.

## Context

- Agent Sessions repository: `/Users/alexm/Repository/Codex-History`
- Preparation document:
  `/Users/alexm/Repository/Codex-History/docs/superpowers/plans/2026-08-30-dsh-source-PREP.md`
- DeepSeek Harness checkout:
  `/Users/alexm/Repository/deepseek-harness`
- Target release: 5.2, `versionIntroduced = "5.2"`
- The DeepSeek checkout currently reports session format v3; the PREP document
  records the source evidence and stale claims that must be reconciled.

The sibling DeepSeek checkout is explicitly in scope for read-only inspection.
Do not inspect private session contents under `~/.dsh`, credentials, `.env`
files, or other secret material. Do not make network calls. Use only the local
source checkout, existing synthetic fixtures, and Agent Sessions source/docs.

## Required evaluation

1. Read the complete PREP document and verify every material claim against the
   current DeepSeek checkout. Mark each claim as confirmed, stale, inferred, or
   unresolved with exact file and line citations.
2. Inspect Agent Sessions’ existing source integrations, especially the source
   descriptor/registry contract, parser and discovery/indexer boundaries,
   session model, archive behavior, resume affordances, fixture conventions,
   target membership, and semantic switch arms.
3. Decide the smallest safe v1 scope for read-only history. Explicitly decide
   what is supported, deferred, or rejected for:
   - v3 plus historical v0/v1/v2 generations;
   - concatenated Zstandard frames and torn-tail recovery;
   - embedded assistant streams versus historical packed rows;
   - source-event provenance and sequence continuity;
   - subagents, forks, seeded prefixes, and archive state;
   - headless, Web, SDK, ACP, Desktop, and custom/out-of-tree TUI resume;
   - search, analytics, attachments, and live follow.
4. Identify evidence that cannot be established from source alone. Define the
   exact synthetic fixtures, steward-supplied non-private fixtures, or manual
   verification needed, without probing private `~/.dsh` data.

## Required plan output

Write the implementation plan to:

`/Users/alexm/Repository/Codex-History/docs/superpowers/plans/2026-09-18-dsh-source-implementation-plan.md`

The plan must be executable end to end and include:

- objective, non-goals, and release boundary;
- current-source authority and an evidence table;
- proposed Agent Sessions files and exact integration points;
- data flow from discovery through generation selection, frame decoding,
  historical normalization, model mapping, indexing, and display;
- migration/recovery strategy and explicit incomplete/corrupt-state behavior;
- resume and archive decisions by surface;
- fixture matrix covering v0/v1/v2/v3, compression, encoding mismatch, legacy
  layout, no-cwd, subagents, forks, packed history, embedded streams, sequence
  ranges, torn frames, and migration failures;
- test plan, build/target-membership checks, and acceptance gates;
- risks, unresolved decisions, and the smallest safe follow-up experiments;
- exact file and line citations for every source-grounded claim.

Use the repository’s existing planning style. Separate confirmed evidence from
hypotheses and decisions. Do not quietly turn a source gap into a product
promise. Leave the implementation untouched when the plan is complete.
