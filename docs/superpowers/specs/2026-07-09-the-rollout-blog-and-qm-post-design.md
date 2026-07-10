# The Rollout — blog surface + first post (Quota Meter)

Date: 2026-07-09
Status: **Proposed** (awaiting review)

## Goal

Stand up a content surface on the Agent Sessions site and ship a first post.
The program serves three pillars, phased: **SEO/discovery**, **credibility/deep
technical**, and **release momentum**. Authoring model: AI-drafted (in a
separate, appropriately-tiered CLI session so reasoning effort is not capped by
the orchestration session), owner reviews, then publish. Cadence floor =
release-anchored; SEO/technical posts drafted opportunistically.

This spec covers the **surface** and the **first post only** (Quota Meter).
Later posts each get their own lightweight draft → review → publish pass; they do
not need new specs unless the surface changes.

## Decisions (locked)

- **Publication name:** "The Rollout" (nav/hero display label).
  - Rationale: no collision with the app's core noun "sessions"; triple meaning
    (release rollouts / Codex "rollout JSONL" / shipping); reads as a real
    publication and scales to a newsletter later.
- **URL:** `/blog/` index, `/blog/<slug>/` per post. `/blog/` is what Google,
  RSS readers, and humans expect — best for the SEO goal. Display name and URL
  are intentionally decoupled.
- **Engine:** Jekyll (native to GitHub Pages — already running on this site;
  no self-run build step).

## Surface — Jekyll scaffold

GitHub Pages already runs Jekyll (there is no `docs/.nojekyll`). The existing
`index.html` and `guides/*.html` have **no YAML front matter**, so Jekyll copies
them through unchanged. Adding a config + layouts is additive.

Files to add under `docs/`:

- `_config.yml`
  - `title`, `description`, `url: https://jazzyalex.github.io`, `baseurl: /agent-sessions`
  - `plugins: [jekyll-feed, jekyll-seo-tag]` (both are on the GitHub Pages
    allow-list, so they run server-side with no CI)
  - `exclude:` list that stops the ~47 internal `.md` specs/plans in `docs/`
    (and `docs/superpowers/`, `docs/adr/`, `docs/deep-dive/`, etc.) from
    rendering as public pages. This also fixes a pre-existing leak.
  - Restrict post collection to `_posts/` only.
- `_layouts/blog.html` — "The Rollout" landing (post list: title, date, excerpt).
- `_layouts/post.html` — single-post template; reuses `guides/guide.css` (copied
  or referenced) so posts match the site's look; includes `{% seo %}` and
  article OG/Twitter tags.
- `blog/index.html` — front-matter `layout: blog`, `permalink: /blog/`.
- `_posts/2026-07-09-quota-meter-burn-rate.md` — the first post.
- Nav link **"The Rollout" → `/blog/`** added to `index.html` and to the guide
  header (`guides/*.html` share a header block).
- RSS: `/feed.xml` generated automatically by `jekyll-feed`.

**Verification before publish:** run `bundle exec jekyll build` (or the
`github-pages` gem) locally and confirm `index.html` and each `guides/*.html`
render byte-identical to the current live pages (diff the built output). Confirm
`/blog/` lists the post, `/feed.xml` validates, and the excluded specs 404.

**Risk / mitigation:**

- *Existing pages change appearance* → they have no front matter; Jekyll passes
  them through. Verified by the byte-diff gate above.
- *Internal specs already leak as pages* → fixed by `exclude:`.
- *Plugin not on Pages allow-list* → `jekyll-feed` and `jekyll-seo-tag` both are;
  no other plugins used.

## First post — Quota Meter

**Lead angle:** Hybrid — problem → math → payoff (broadest reach; serves SEO and
credibility together).

**Working title:** "Your AI coding limit runs out mid-task. Here's the math that
sees it coming."
Alt: "How much of your Claude or Codex limit is left — and the burn-rate behind
Session Runway."

**Target keywords:** `claude 5 hour limit`, `when does claude limit reset`,
`codex usage limit`, `how much claude limit left`, `ai coding agent usage tracking`.

**Length:** ~1,300–1,700 words. 2–3 screenshots.

**Structure:**

1. **Hook / problem.** Mid-task, the agent stops. The 5-hour *rolling* window +
   weekly caps. Why a static "7% used" is useless — it is not a trajectory and
   never tells you *when* you run out.
2. **Why the naive read misleads.** Whole-percent resolution; cache cadence; a
   percentage vs. a rate.
3. **The math (credibility core).** Burn-rate from token attribution; the rolling
   5h window; the projection needs two samples ≥60s apart showing a drop with
   run-out before reset; **Session Runway** = per-session burn bars; burn is
   *decoupled* from the projection so it renders from token attribution
   regardless of freshness; **Codex CLI-RPC (fine-grained, "fresh") vs Claude
   OAuth cache (coarse, whole-percent)** — presented honestly as a deliberate
   tradeoff (avoids OAuth 429s, cooperates with the Claude Code statusline).
4. **The payoff.** What you actually see: the meter, the "smile" when on-track,
   Runway spotting the session eating your quota, the ETA badge. Screenshots.
5. **Soft CTA.** Free, local-only, no telemetry → download / GitHub.

**Accuracy guardrails (for the writing session):** verify every mechanical claim
against source; do not invent numbers. Primary sources:

- `docs/claude-usage-projection-freshness.md` (cadence, cache-first 180s,
  whole-percent, projection conditions, burn/projection decoupling)
- `AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift`
- `AgentSessions/ClaudeStatus/ClaudeRunwayTokenActivityParser.swift`
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift`
- `AgentSessions/CodexStatus/CodexRunwayModel.swift`
- `AgentSessions/CodexStatus/UsageDisplayMode.swift`

**Do NOT** claim Claude reaches "fresh" projection parity with Codex — it is
coarse by design. Sell the honesty of the tradeoff, not a false parity. This is
the credibility hinge of the post.

**Screenshots needed (owner action):** current Quota Meter (light), Session
Runway per-session bars, and either the "smile"/on-track state or the ETA badge.
Reuse `docs/assets/quota-meter-light.png` / `quota-meter-runway.gif` if still
representative; capture fresh if the 4.3 UI differs.

## Distribution kit (drafted alongside the post)

- **X:** short thread — problem hook → the one non-obvious idea (rate, not
  percent) → screenshot → link.
- **LinkedIn:** professional framing — staying in flow, not losing a task to an
  invisible limit; developer-productivity angle.
- **Reddit:** value-first, product-neutral body that stands on its own; match
  each subreddit's norms; lead with the insight, not the download. Verify the
  target subreddit's self-promo rules before posting.

Guardrails from the existing outreach playbook apply: quote real sources, keep
X ≤280 chars, do not spam.

## Draft → review → publish pipeline (repeatable)

1. Orchestration session writes a per-post brief (this spec is the template).
2. A separate CLI session with an appropriately-tiered writing agent drafts the
   post + distribution kit against the source guardrails.
3. Owner reviews the draft.
4. On approval: add the `_posts/*.md` file, build + byte-diff gate, publish
   (commit + push `docs/`); GitHub Pages serves it.

## Out of scope (for now)

- Custom domain / CNAME (site stays `jazzyalex.github.io/agent-sessions`).
- Email newsletter, comments, analytics beyond what the site already has.
- The other launch-batch posts (origin story, 9-format parser, perf war story) —
  drafted later on the same pipeline.
