# The Rollout Blog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up "The Rollout" blog surface (`/blog/`, RSS, SEO tags) on the existing GitHub Pages site via a Jekyll config + layouts, without changing a byte of what the site currently serves that matters — and produce the handoff brief for the first post (Quota Meter), which is written in a separate session.

**Architecture:** GitHub Pages already builds `main:/docs` with legacy Jekyll (verified via `gh api repos/jazzyalex/agent-sessions/pages`: `build_type: "legacy"`, source `main` `/docs`). Existing `index.html` / `guides/*.html` have no YAML front matter, so Jekyll static-copies them byte-for-byte; the blog is purely additive (`_config.yml`, `_layouts/`, `blog/`, `_posts/`). Safety is enforced empirically: a baseline build (no config) vs. new build manifest diff, plus source-vs-output byte comparison for every surviving file.

**Tech Stack:** Jekyll 3.x via the `github-pages` gem (local Ruby 3.2.2 + rbenv + bundler confirmed present), `jekyll-feed`, `jekyll-seo-tag`, `jekyll-sitemap`, plain HTML/CSS reusing `guides/guide.css`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-the-rollout-blog-and-qm-post-design.md` (authoritative). Locked: publication name **"The Rollout"**, URL **`/blog/`** index + **`/blog/<slug>/`** per post, engine **Jekyll**.
- Voice guardrails for all post/social copy: `docs/superpowers/the-rollout-voice.md` (the Phase B brief must hard-point to it).
- **Never commit or push without explicit owner approval** (repo rule). Commit steps below are owner-gated and stage exact paths only (`git commit -- <paths>` discipline).
- **Do not run the `deploy` skill or any release tooling.** This is site content only.
- **Sparkle must keep working:** `docs/appcast.xml` is the live update feed (`SUFeedURL` in `AgentSessions/Info.plist:31`). It and `docs/assets/**`, `docs/guides/**`, `docs/index.html` must remain served and byte-identical. This is the highest-severity regression risk in the whole plan.
- Commit messages: Conventional Commits, Tool/Model/Why trailers only, no "Generated with Claude Code" footer, no Co-Authored-By.
- The first post is NOT written in this plan. Phase B produces the writing brief; a separate appropriately-tiered session drafts the post.
- All templates use `{{ '/path' | relative_url }}` for site-internal URLs (never hardcode `/blog/` or `/agent-sessions/` in layouts).
- Local build artifacts (bundler vendor dir, `_site` output, manifests) go to a temp/scratch dir, never inside `docs/` and never committed. `docs/Gemfile` + `docs/Gemfile.lock` ARE committed (reproducible builds) and excluded from the site.

---

## Spec review findings

Overall verdict: **the spec is sound and the architecture is right** — legacy Jekyll build confirmed, additive config, correct URL/name split. Several assumptions needed correction or tightening:

1. **Foundation assumption verified true.** Pages builds `main:/docs` with `build_type: "legacy"` (real Jekyll build, not a static workflow). No `docs/.nojekyll`, no `docs/_config.yml`, no `docs/CNAME` exist. Adding a config is genuinely additive.

2. **The "leak" framing is slightly wrong, but the fix is still right.** Zero `.md` files under `docs/` have YAML front matter (verified by scan), so Jekyll never *renders* them as pages — they are static-copied and served **raw** (verified live: `…/CHANGELOG.md` returns HTTP 200 today). The `exclude:` fix and the "excluded specs 404" gate are both still correct; only the mechanism description in the spec is off.

3. **Critical omission: the spec's exclude discussion never names the must-keep set, and the appcast is in the blast radius.** `docs/appcast.xml` is the Sparkle `SUFeedURL` — an over-broad exclude would silently break auto-update for every installed copy of the app. The plan adds an explicit must-keep list (`index.html`, `appcast.xml`, `assets/`, `guides/`) and byte-verifies `appcast.xml` in every build gate and again live after publish. (The two root mockup HTMLs `cockpit-mockup.html` / `cockpit-hud-mockup.html` are internal and are *excluded*, per owner decision — see finding 10.)

4. **`exclude:` vs. `include:` allow-list: use enumerated `exclude:`, verified empirically.** Jekyll has no true allow-list mode — `include:` only re-adds items that defaults excluded; inverting via `exclude: ["*"]` + `include:` is fragile on Jekyll 3.x and not worth it. Two Jekyll-3 gotchas the spec missed: (a) a user `exclude:` list **replaces** the built-in defaults on 3.x (Jekyll 4 merges), so `Gemfile`/`vendor`/`node_modules` must be repeated explicitly; (b) glob semantics for `"*.md"` differ across 3.x point versions (may or may not cross `/`). Rather than trusting either, the plan's gate is a **manifest diff**: build once with no config (baseline = what's live today), once with the new config, and require the diff to equal exactly the intended removals + additions. That makes the exclude list's correctness an observed fact, not an assumption. Exact list to exclude: dirs `adr`, `agent-support`, `analytics`, `deep-dive`, `mockups`, `plans`, `release`, `schemas`, `snippets`, `summaries`, `superpowers`, `updates`, `vision`, plus root `"*.md"` (47 files incl. `CHANGELOG.md`, `PRIVACY.md` — nothing live links to them; the app About button and appcast link only to the site root and GitHub), plus the two root mockup HTMLs `cockpit-mockup.html` and `cockpit-hud-mockup.html` (owner decision, finding 10), plus tooling `Gemfile`, `Gemfile.lock`, `vendor`, `node_modules`. (`_preview/`, `_banner-preview/` already 404 via the underscore rule — verified live.)

5. **The byte-identical gate is achievable — but diff source vs. built output, not vs. live-over-curl.** Files without front matter are static-copied, so `cmp docs/<f> _site/<f>` must pass exactly. Curling the live CDN adds noise (headers, compression) for no extra signal. Refined gate: (a) manifest diff as in finding 4; (b) `cmp` every surviving file against its source. If (a) and (b) pass locally with the `github-pages` gem, the live result follows (same builder).

6. **`baseurl` is safe for existing pages, load-bearing for new ones.** Existing pages are static-copied, so their hardcoded `https://jazzyalex.github.io/agent-sessions/...` and `../assets/...` links are untouched. New layouts must use `relative_url` everywhere (posts at `/blog/<slug>/` and the index at `/blog/` sit at different depths — naked relative paths would break). `url: https://jazzyalex.github.io` + `baseurl: /agent-sessions` also makes `jekyll-feed`/`jekyll-seo-tag` emit correct absolute URLs. Local preview serves at `http://127.0.0.1:4000/agent-sessions/`. The nav link added to `index.html` should be relative `href="blog/"` (matching its existing `guides/...` links) so it works on any host.

7. **`guide.css`: reference it, don't copy it.** Recommendation: posts link `{{ '/guides/guide.css' | relative_url }}` plus a thin blog-only `blog/blog.css` overlay. Rationale: single source of design truth; `guide.css` is small (212 lines) and stable; a copy would drift the moment guides get restyled. Trade-off accepted and worth stating out loud: `guide.css` is **light-mode only** (no `prefers-color-scheme`), so posts will match the guides' look, not the dark-capable landing page. That is consistent with "posts match the site's look" as the guides define it; dark-mode posts are future work, not this plan.

8. **Plugin allow-list claim checks out.** `jekyll-feed`, `jekyll-seo-tag`, and `jekyll-sitemap` (added per owner decision, finding 10) all ship inside the `github-pages` gem (the Pages whitelist), run server-side, no CI needed. No other plugins are used. One nuance: `jekyll-feed` titles the feed from `site.title` ("Agent Sessions", not "The Rollout") — acceptable, noted so nobody "fixes" it by renaming the whole site. `jekyll-sitemap` emits `/sitemap.xml` listing only the served pages (excluded internal docs never appear), so it doubles as a leak sentinel.

9. **Underspecified in the spec, decided here:** post permalink style (`permalink: /blog/:title/`), `timezone: America/Los_Angeles` (post dates/URLs shift a day without it), `{% seo %}` is the *only* meta source in blog layouts (no hand-authored duplicate OG tags), the `_posts/` filename date must be re-stamped to the actual publish date at publish time, and local verification uses a **throwaway sample post that is never committed** (no lorem ipsum ships). The spec's "restrict post collection to `_posts/` only" is a no-op — that is Jekyll's default; no config key exists to write. The spec's claim that `guides/*.html` "share a header block" is wrong: the header is duplicated per file, so the nav link means one small edit in each of the 6 guide files.

10. **Open questions — RESOLVED by owner (2026-07-09):**
    - *Root mockup HTMLs (`cockpit-mockup.html`, `cockpit-hud-mockup.html`) — keep serving or exclude?* → **EXCLUDE.** Both are internal; they join the exclude list (Task 2) and are expected removals in the manifest-diff gate. They were never linked from any live page, so removing them is safe.
    - *Add `jekyll-sitemap`?* → **YES.** Added to the `_config.yml` plugins list; `/sitemap.xml` becomes a second generated addition (alongside `/feed.xml`) in every manifest-diff gate and byte-identity skip list.
    - *Ship the surface with the first post, or publish an empty `/blog/` earlier?* → **BUNDLE with the finished first post** (Phase C ships surface + post together). No structural change to this plan.

---

## File Structure

Created (Phase A):
- `docs/Gemfile` — pins `github-pages` for local builds (excluded from site).
- `docs/_config.yml` — site config: url/baseurl, plugins, permalink style, exclude list.
- `docs/_layouts/blog.html` — base chrome for all blog pages (header/footer, guide.css + blog.css, `{% seo %}`, feed link).
- `docs/_layouts/post.html` — single-post article wrapper (chains to `blog`).
- `docs/blog/index.html` — "The Rollout" landing at `/blog/` (post list).
- `docs/blog/blog.css` — blog-only styles layered over `guides/guide.css`.

Modified (Phase A):
- `docs/index.html` — one nav link (`The Rollout → blog/`) in `.nav-links` (~line 412).
- `docs/guides/*.html` (6 files) — one link in each `.header-right`.

Created (Phase B):
- `docs/superpowers/briefs/2026-07-09-quota-meter-post-brief.md` — the writing-session handoff packet (excluded from the site via `superpowers` exclude).

Created (Phase C, by the separate writing session, added at publish):
- `docs/_posts/YYYY-MM-DD-quota-meter-burn-rate.md` — the approved first post (date = publish date).

Never committed: sample smoke-test post, `Gemfile.lock`'s vendor dir, `_site` output, manifests (all live in a scratch dir; `Gemfile.lock` itself IS committed).

---

# Phase A — Jekyll scaffold

### Task 1: Local toolchain + baseline build (no site changes)

Captures what the live site serves *today* as a manifest, before any config exists. This baseline is the "failing test" every later task diffs against.

**Files:**
- Create: `docs/Gemfile`

**Interfaces:**
- Consumes: nothing.
- Produces: `$SCRATCH/baseline-manifest.txt` (file list of the default-config build) and a working `bundle exec jekyll` toolchain rooted at `docs/`. All later tasks use `SCRATCH="${TMPDIR:-/tmp}/rollout-build"` and `BUNDLE_PATH="$SCRATCH/vendor"`.

- [ ] **Step 1: Create the Gemfile**

Create `docs/Gemfile`:

```ruby
source "https://rubygems.org"
gem "github-pages", group: :jekyll_plugins
```

- [ ] **Step 2: Install the toolchain (vendor dir outside the repo)**

Run:
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"; mkdir -p "$SCRATCH"
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle install
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll --version
```
Expected: install succeeds; version prints `jekyll 3.10.x` (the Pages-pinned line). If `bundle install` fails on native extensions, note the Ruby in use (`ruby --version` should be 3.2.2 via rbenv) and stop — do not switch Ruby versions without telling the owner.

- [ ] **Step 3: Baseline build with NO config and capture the manifest**

Run:
```bash
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-baseline"
( cd "$SCRATCH/site-baseline" && find . -type f | sort ) > "$SCRATCH/baseline-manifest.txt"
wc -l "$SCRATCH/baseline-manifest.txt"
grep -c '\.md$' "$SCRATCH/baseline-manifest.txt"
```
Expected: build succeeds; manifest has several hundred entries; the `.md` count is ≥47 (the leak, present in baseline as expected). `Gemfile`/`Gemfile.lock` may or may not appear in the baseline (Pages default excludes vary) — either is fine; the Task 2 diff accounts for them.

- [ ] **Step 4: Verify baseline passthrough is byte-identical (sanity for the whole approach)**

Run:
```bash
cmp docs/index.html "$SCRATCH/site-baseline/index.html" && echo "INDEX IDENTICAL"
cmp docs/appcast.xml "$SCRATCH/site-baseline/appcast.xml" && echo "APPCAST IDENTICAL"
```
(from repo root). Expected: both lines print. If not, STOP — the static-copy assumption is wrong and the spec's whole approach needs re-review.

- [ ] **Step 5: Commit (owner-gated)**

Ask the owner; on approval:
```bash
git add docs/Gemfile docs/Gemfile.lock
git commit -m "chore(site): pin github-pages gem for local Jekyll builds" -- docs/Gemfile docs/Gemfile.lock
```

---

### Task 2: `_config.yml` + manifest-diff verification

The config that turns on the blog machinery and turns off the internal-doc leak. The manifest diff is the acceptance test.

**Files:**
- Create: `docs/_config.yml`

**Interfaces:**
- Consumes: `$SCRATCH/baseline-manifest.txt` (Task 1).
- Produces: a config later tasks build on; the verified guarantee "only intended removals/additions" that Phase C's gate re-runs.

- [ ] **Step 1: Write the config**

Create `docs/_config.yml`:

```yaml
# Site config for jazzyalex.github.io/agent-sessions (GitHub Pages, legacy Jekyll build).
# Existing HTML pages have no front matter and pass through byte-identical.
# This config adds "The Rollout" blog (/blog/) and stops internal docs from being served.
title: Agent Sessions
description: >-
  Local history, search, and usage tracking for AI coding agents on macOS —
  Codex, Claude Code, Cursor, OpenCode, Copilot, and more.
url: "https://jazzyalex.github.io"
baseurl: "/agent-sessions"
timezone: America/Los_Angeles

plugins:
  - jekyll-feed
  - jekyll-seo-tag
  - jekyll-sitemap

# Posts render at /blog/<slug>/
permalink: /blog/:title/

defaults:
  - scope:
      type: posts
    values:
      layout: post

# MUST KEEP SERVED (never add to exclude): index.html, appcast.xml (Sparkle
# SUFeedURL — breaking this breaks auto-update), assets/, guides/, blog/.
#
# NOTE: on the Pages Jekyll (3.x) this list REPLACES the built-in defaults,
# so the tooling entries are repeated here explicitly.
exclude:
  # build tooling
  - Gemfile
  - Gemfile.lock
  - vendor
  - node_modules
  # internal directories (specs, plans, ops docs, mockups)
  - adr
  - agent-support
  - analytics
  - deep-dive
  - mockups
  - plans
  - release
  - schemas
  - snippets
  - summaries
  - superpowers
  - updates
  - vision
  # internal root-level mockups (never linked from any live page)
  - cockpit-mockup.html
  - cockpit-hud-mockup.html
  # root-level internal markdown (CHANGELOG.md, PRIVACY.md, specs, plans, ...)
  - "*.md"
```

- [ ] **Step 2: Build and diff the manifest against baseline**

Run:
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-new"
( cd "$SCRATCH/site-new" && find . -type f | sort ) > "$SCRATCH/new-manifest.txt"
diff "$SCRATCH/baseline-manifest.txt" "$SCRATCH/new-manifest.txt" | tee "$SCRATCH/manifest.diff"
```
Expected — the diff contains ONLY:
- Removals (`<` lines): every `*.md` path, everything under the 13 excluded dirs, the two root mockups `./cockpit-mockup.html` and `./cockpit-hud-mockup.html`, `./Gemfile`, `./Gemfile.lock` (if they were in baseline). Nothing else.
- Additions (`>` lines): `./feed.xml` and `./sitemap.xml` (no posts or blog index exist yet).

Any unexpected removal — especially `./appcast.xml`, anything under `./assets/`, `./guides/`, or `./index.html` — is a FAIL: fix the exclude list before proceeding. (The two mockups are *expected* removals, not protected — they are deliberately excluded, so they must NOT appear in the protected-set grep below.) Verify explicitly:
```bash
grep -E '^(<|>).*(appcast\.xml|/assets/|/guides/|\./index\.html)' "$SCRATCH/manifest.diff" && echo "FAIL: protected file affected" || echo "PROTECTED SET UNTOUCHED"
grep -E '^<.*(cockpit-mockup\.html|cockpit-hud-mockup\.html)' "$SCRATCH/manifest.diff" && echo "MOCKUPS REMOVED (expected)" || echo "FAIL: mockups still served"
grep -c '\.md$' "$SCRATCH/new-manifest.txt"
```
Expected: `PROTECTED SET UNTOUCHED`, `MOCKUPS REMOVED (expected)`, and the `.md` count in the new manifest is `0`.

- [ ] **Step 3: Byte-identity check for every surviving file**

Run (from repo root):
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"
fails=0
while IFS= read -r f; do
  case "$f" in "./feed.xml"|"./sitemap.xml") continue;; esac
  cmp -s "docs/${f#./}" "$SCRATCH/site-new/${f#./}" || { echo "DIFFERS: $f"; fails=$((fails+1)); }
done < "$SCRATCH/new-manifest.txt"
echo "BYTE-DIFF FAILURES: $fails"
```
Expected: `BYTE-DIFF FAILURES: 0`. This is the spec's "byte-identical" gate, made concrete: every served file except the generated `feed.xml` and `sitemap.xml` is a verbatim copy of its source.

- [ ] **Step 4: Commit (owner-gated)**

Ask the owner; on approval:
```bash
git add docs/_config.yml
git commit -m "feat(site): Jekyll config — blog plumbing + stop serving internal docs" -- docs/_config.yml
```

---

### Task 3: Layouts + blog stylesheet

**Files:**
- Create: `docs/_layouts/blog.html`
- Create: `docs/_layouts/post.html`
- Create: `docs/blog/blog.css`

**Interfaces:**
- Consumes: `guides/guide.css` classes (`header`, `.brand`, `.header-right`, `.guide-shell`, `.eyebrow`, `.lede`, `.site-footer`) and `guides/guide.js` (year + star count) — referenced, not copied (finding 7).
- Produces: layout names `blog` and `post` used by Task 4's `blog/index.html` front matter and by every `_posts/*.md`; CSS classes `post-list`, `post-meta`, `post-excerpt`, `post`, `post-back` used by Task 4 and the post template.

- [ ] **Step 1: Write the base layout**

Create `docs/_layouts/blog.html`:

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  {% seo %}
  <link rel="alternate" type="application/rss+xml" title="The Rollout — Agent Sessions" href="{{ '/feed.xml' | relative_url }}">
  <link rel="icon" href="{{ '/assets/app-icon-32.png' | relative_url }}">
  <link rel="stylesheet" href="{{ '/guides/guide.css' | relative_url }}">
  <link rel="stylesheet" href="{{ '/blog/blog.css' | relative_url }}">
  <script defer src="{{ '/guides/guide.js' | relative_url }}"></script>
</head>
<body>
  <header>
    <div class="brand">
      <a href="{{ '/' | relative_url }}"
        style="display:flex;align-items:center;gap:12px;text-decoration:none;color:inherit;">
        <img src="{{ '/assets/app-icon-512.png' | relative_url }}" alt="Agent Sessions app icon" width="40" height="40"
          style="border-radius:6px;">
        <h1 style="margin:0;font-size:20px;">Agent Sessions</h1>
      </a>
    </div>
    <div class="header-right">
      <a href="{{ '/blog/' | relative_url }}">The Rollout</a>
      <span>• macOS • Open Source • <span id="github-stars-container" style="display:none;">⭐ <span
            id="github-stars">–</span></span></span>
    </div>
  </header>
  <main class="guide-shell">
    {{ content }}
  </main>
  <footer class="site-footer">&copy; <span id="year"></span> Agent Sessions. Local-first, open source, and independent.</footer>
</body>
</html>
```

Notes locked in: `{% seo %}` emits `<title>`, canonical, OG, and Twitter tags — do NOT add hand-authored duplicates (finding 9). Every internal URL goes through `relative_url` (finding 6).

- [ ] **Step 2: Write the post layout**

Create `docs/_layouts/post.html`:

```html
---
layout: blog
---
<article class="post">
  <p class="eyebrow">The Rollout</p>
  <h1>{{ page.title }}</h1>
  <p class="post-meta"><time datetime="{{ page.date | date_to_xmlschema }}">{{ page.date | date: "%B %-d, %Y" }}</time></p>
  {{ content }}
  <p class="post-back"><a href="{{ '/blog/' | relative_url }}">&larr; The Rollout</a></p>
</article>
```

Deliberate: no baked-in CTA — the voice guide makes the CTA the writer's one honest line inside the post body, not template chrome.

- [ ] **Step 3: Write the blog stylesheet**

Create `docs/blog/blog.css`:

```css
/* The Rollout — blog-only styles, layered over guides/guide.css. */

.post-list {
  list-style: none;
  padding-left: 0;
  max-width: 860px;
}

.post-list li {
  padding: 18px 0;
  border-bottom: 1px solid #d0d7de;
}

.post-list h2 {
  margin: 0 0 4px;
  font-size: 22px;
}

.post-list h2 a {
  text-decoration: none;
}

.post-meta {
  color: #57606a;
  font-size: 14px;
  margin: 0 0 8px;
}

.post-excerpt {
  margin: 6px 0 0;
  color: #3d444d;
}

article.post {
  max-width: 860px;
}

article.post img {
  max-width: 100%;
  height: auto;
  border: 1px solid #d0d7de;
  border-radius: 8px;
}

.post-back {
  margin-top: 40px;
}
```

- [ ] **Step 4: Build to verify layouts are inert without pages**

Run:
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-new"
test -f "$SCRATCH/site-new/blog/blog.css" && echo "BLOG CSS SERVED"
test ! -e "$SCRATCH/site-new/_layouts" && echo "LAYOUTS NOT SERVED"
```
Expected: both lines print; no build errors (a Liquid error in a layout fails the build — that is the test).

- [ ] **Step 5: Commit (owner-gated)**

Ask the owner; on approval:
```bash
git add docs/_layouts/blog.html docs/_layouts/post.html docs/blog/blog.css
git commit -m "feat(site): The Rollout layouts (blog, post) + blog stylesheet" -- docs/_layouts/blog.html docs/_layouts/post.html docs/blog/blog.css
```

---

### Task 4: Blog index + end-to-end smoke with a throwaway post

**Files:**
- Create: `docs/blog/index.html`
- Create (TEMPORARY, never committed): `docs/_posts/2026-07-09-scaffold-smoke-test.md`

**Interfaces:**
- Consumes: layouts `blog`/`post` and classes from Task 3.
- Produces: `/blog/` (permalink) that Phase C's live checks hit; proof that `permalink: /blog/:title/`, the post list, excerpts, and `feed.xml` all work.

- [ ] **Step 1: Write the blog index**

Create `docs/blog/index.html`:

```html
---
layout: blog
title: The Rollout
description: Notes from building Agent Sessions — usage math, local agent-session formats, and what shipped.
permalink: /blog/
---
<p class="eyebrow">Agent Sessions</p>
<h1>The Rollout</h1>
<p class="lede">Notes from building Agent Sessions: usage math, local agent-session formats, and what shipped.</p>

<ul class="post-list">
  {% for post in site.posts %}
  <li>
    <h2><a href="{{ post.url | relative_url }}">{{ post.title }}</a></h2>
    <p class="post-meta"><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%B %-d, %Y" }}</time></p>
    <p class="post-excerpt">{{ post.excerpt | strip_html | normalize_whitespace | truncate: 200 }}</p>
  </li>
  {% endfor %}
</ul>
```

- [ ] **Step 2: Create the throwaway smoke-test post**

Create `docs/_posts/2026-07-09-scaffold-smoke-test.md` (DELETE in Step 5 — never commit):

```markdown
---
title: "Scaffold smoke test (never publish)"
description: "Temporary post that verifies the blog scaffold locally."
---
First paragraph exercises the excerpt on the index page.

Second paragraph has `inline code` and a [link](https://github.com/jazzyalex/agent-sessions) to exercise post-body styling.
```

- [ ] **Step 3: Build and verify the full blog pipeline**

Run:
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-new"
test -f "$SCRATCH/site-new/blog/index.html" && echo "BLOG INDEX BUILT"
test -f "$SCRATCH/site-new/blog/scaffold-smoke-test/index.html" && echo "POST PERMALINK OK"
grep -q 'scaffold-smoke-test' "$SCRATCH/site-new/blog/index.html" && echo "INDEX LISTS POST"
grep -q 'https://jazzyalex.github.io/agent-sessions/blog/scaffold-smoke-test/' "$SCRATCH/site-new/feed.xml" && echo "FEED URL ABSOLUTE+CORRECT"
xmllint --noout "$SCRATCH/site-new/feed.xml" && echo "FEED VALID XML"
grep -q 'guides/guide.css' "$SCRATCH/site-new/blog/scaffold-smoke-test/index.html" && echo "GUIDE CSS REFERENCED"
grep -q 'property="og:title"' "$SCRATCH/site-new/blog/scaffold-smoke-test/index.html" && echo "SEO TAGS PRESENT"
```
Expected: all six echo lines print.

- [ ] **Step 4: Visual check (owner optional, recommended)**

Run:
```bash
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll serve -d "$SCRATCH/site-serve"
```
Tell the owner to open `http://127.0.0.1:4000/agent-sessions/blog/` and the smoke post, and confirm it reads like a guide page (header, type, spacing). Stop the server after.

- [ ] **Step 5: Delete the smoke-test post and rebuild clean**

Run:
```bash
rm /Users/alexm/Repository/Codex-History/docs/_posts/2026-07-09-scaffold-smoke-test.md
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-new"
test ! -e "$SCRATCH/site-new/blog/scaffold-smoke-test" && echo "SMOKE POST GONE"
git status --porcelain docs/_posts/ ; echo "(expect empty)"
```
Expected: `SMOKE POST GONE`; `git status` shows nothing under `docs/_posts/`.

- [ ] **Step 6: Commit (owner-gated)**

Ask the owner; on approval:
```bash
git add docs/blog/index.html
git commit -m "feat(site): The Rollout landing at /blog/" -- docs/blog/index.html
```

---

### Task 5: Nav links on existing pages + full re-verification

The only task that edits currently-served files. Each edit is one added line; the Task 2 byte gate no longer applies to these files (they change on purpose), so verification is: build passes, links resolve, and nothing else in the file changed (`git diff` shows exactly one added line per file).

**Files:**
- Modify: `docs/index.html` (~line 412, inside `.nav-links`)
- Modify: `docs/guides/claude-code-jsonl-history.html`, `docs/guides/codex-local-history.html`, `docs/guides/cursor-agent-local-history.html`, `docs/guides/hermes-agent-state-db-history.html`, `docs/guides/openclaw-local-agent-history.html`, `docs/guides/opencode-sqlite-history.html` (each `.header-right`)

**Interfaces:**
- Consumes: `/blog/` from Task 4.
- Produces: the user-visible entry points the spec requires ("The Rollout" in the landing nav and guide headers).

- [ ] **Step 1: Add the landing-page nav link**

In `docs/index.html`, the nav block currently reads:

```html
      <div class="nav-links">
        <a class="hide-sm" href="#features">Features</a>
        <a class="hide-sm" href="#cockpit">Quota Meter</a>
        <a class="hide-sm" href="#guides">Guides</a>
        <a href="https://github.com/jazzyalex/agent-sessions">GitHub<span class="nav-star" id="gh-stars"></span></a>
      </div>
```

Add one line after the Guides link (relative `blog/` — matches the file's existing relative `guides/...` links and works under baseurl):

```html
        <a class="hide-sm" href="blog/">The Rollout</a>
```

- [ ] **Step 2: Add the guide-header link to all 6 guide files**

First confirm the block is identical across files:
```bash
grep -c '<div class="header-right">' docs/guides/*.html
```
Expected: `1` per file. Then in EACH guide file, change:

```html
    <div class="header-right">
      <span>• macOS • Open Source •
```

to:

```html
    <div class="header-right">
      <a href="../blog/">The Rollout</a>
      <span>• macOS • Open Source •
```

(The `<span>` line's tail differs slightly per file; anchor the edit on the `header-right` opening line and insert the `<a>` line after it.)

- [ ] **Step 3: Verify the diffs are exactly one line per file**

Run:
```bash
git diff --stat docs/index.html docs/guides/
git diff docs/index.html docs/guides/ | grep '^+' | grep -v '^+++' | sort | uniq -c
```
Expected: 7 files, `+1` each; the added lines are only the two `<a ...>The Rollout</a>` variants.

- [ ] **Step 4: Rebuild and check every nav href resolves in the built site**

Run:
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-new"
test -f "$SCRATCH/site-new/blog/index.html" && echo "TARGET EXISTS"
cmp docs/appcast.xml "$SCRATCH/site-new/appcast.xml" && echo "APPCAST STILL IDENTICAL"
cmp docs/index.html "$SCRATCH/site-new/index.html" && echo "INDEX PASSTHROUGH (with nav edit) IDENTICAL"
```
(run the `cmp` lines from repo root). Expected: all three lines print.

- [ ] **Step 5: Commit (owner-gated)**

Ask the owner; on approval:
```bash
git add docs/index.html docs/guides/*.html
git commit -m "feat(site): nav link 'The Rollout' on landing page and guides" -- docs/index.html docs/guides/claude-code-jsonl-history.html docs/guides/codex-local-history.html docs/guides/cursor-agent-local-history.html docs/guides/hermes-agent-state-db-history.html docs/guides/openclaw-local-agent-history.html docs/guides/opencode-sqlite-history.html
```

---

# Phase B — First-post handoff brief

### Task 6: Write the Quota Meter post writing brief

Produces the self-contained packet a separate, appropriately-tiered writing session uses to draft the post + distribution kit. This plan does NOT write the post.

**Files:**
- Create: `docs/superpowers/briefs/2026-07-09-quota-meter-post-brief.md`

**Interfaces:**
- Consumes: the spec's "First post" section (angle, titles, keywords, structure, guardrails) and `docs/claude-usage-projection-freshness.md` (mechanics ground truth).
- Produces: the brief file whose path is handed verbatim to the writing session; Phase C consumes that session's output file `docs/_posts/YYYY-MM-DD-quota-meter-burn-rate.md`.

- [ ] **Step 1: Write the brief**

Create `docs/superpowers/briefs/2026-07-09-quota-meter-post-brief.md`:

```markdown
# Writing brief — The Rollout post 1: Quota Meter burn-rate

For: a separate writing session (appropriately tiered — do not draft this in the
orchestration session). Deliverables: ONE post file + a distribution kit. Do not
touch any other file. Do not commit.

## Read these two files before writing a single sentence

1. `docs/superpowers/the-rollout-voice.md` — voice, sarcasm dial, anti-AI-slop
   banlist, litmus tests. HARD requirements, not suggestions. Calibrate against
   the founder's real register (tweets, `Marketing/` Reddit drafts) as it says.
2. `docs/claude-usage-projection-freshness.md` — the mechanics ground truth for
   every claim about cadence, caching, resolution, and the projection.

## Deliverable 1 — the post

File: `docs/_posts/YYYY-MM-DD-quota-meter-burn-rate.md` with YYYY-MM-DD = the
actual publish date (re-stamp the filename at publish). Front matter:

    ---
    title: "<chosen title>"
    description: "<150-160 char meta description hitting the primary keyword>"
    image: /assets/quota-meter-light.png   # or the fresher screenshot's path
    ---

(Layout is applied automatically; do not add a `layout:` key. No hand-authored
OG tags — the template's `{% seo %}` handles that.)

- Length: ~1,300-1,700 words. 2-3 screenshots (see owner actions).
- Angle (locked): problem → math → payoff.
- Title options (pick or beat — problem-first, concrete, per the voice doc):
  - "Your AI coding limit runs out mid-task. Here's the math that sees it coming."
  - "How much of your Claude or Codex limit is left — and the burn-rate behind
    Session Runway."
- Target keywords (work into headings/body naturally, never stuffed):
  `claude 5 hour limit`, `when does claude limit reset`, `codex usage limit`,
  `how much claude limit left`, `ai coding agent usage tracking`.

### Structure (from the approved spec)

1. **Hook / problem.** Mid-task, the agent stops. The 5-hour *rolling* window +
   weekly caps. Why a static "7% used" is useless — not a trajectory, never says
   *when* you run out.
2. **Why the naive read misleads.** Whole-percent resolution; cache cadence; a
   percentage vs. a rate.
3. **The math (credibility core).** Burn-rate from token attribution; the
   rolling 5h window; the projection needs two samples ≥60s apart showing a
   drop, with run-out before reset; Session Runway = per-session burn bars; burn
   is decoupled from the projection (renders from token attribution regardless
   of freshness); Codex CLI-RPC (fine-grained, "fresh") vs Claude OAuth cache
   (coarse, whole-percent) — an honest, deliberate tradeoff (avoids OAuth 429s,
   cooperates with the Claude Code statusline).
4. **The payoff.** The meter, the on-track state, Runway spotting the session
   eating your quota, the ETA badge. Screenshots.
5. **Soft CTA.** One line: free, local-only, no telemetry → download / GitHub.

### Accuracy guardrails (credibility hinge)

Verify EVERY mechanical claim against source before writing it. No invented
numbers. Sources, in order:

- `docs/claude-usage-projection-freshness.md` (cache-first 180s, 60s poll,
  whole-percent resolution, projection conditions, burn/projection decoupling)
- `AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift`
- `AgentSessions/ClaudeStatus/ClaudeRunwayTokenActivityParser.swift`
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift`
- `AgentSessions/CodexStatus/CodexRunwayModel.swift`
- `AgentSessions/CodexStatus/UsageDisplayMode.swift`

**Do NOT** claim Claude reaches "fresh" projection parity with Codex — it is
coarse by design. Sell the honesty of the tradeoff, not a false parity.

### Screenshots (OWNER ACTION — request, don't fabricate)

Needed: current Quota Meter (light), Session Runway per-session bars, and either
the on-track state or the ETA badge. `docs/assets/quota-meter-light.png` and
`docs/assets/quota-meter-runway.gif` exist — reuse only if still representative
of the 4.3 UI; otherwise ask the owner for fresh captures. Reference images in
the post as `![...]({{ '/assets/<file>' | relative_url }})`. Captions read like
a person pointing at the screen (voice doc).

## Deliverable 2 — distribution kit (one file, not published)

File: `docs/superpowers/briefs/2026-07-09-quota-meter-distribution-kit.md`

- **X:** short thread — problem hook → the one non-obvious idea (rate, not
  percent) → screenshot → link. Every tweet ≤280 chars (account is not Premium).
- **LinkedIn:** same substance, more setup, zero corporate mush.
- **Reddit:** value-first, product-neutral body that stands alone; match each
  target sub's norms; verify self-promo rules before proposing a sub.

## Definition of done

- Post passes the voice doc's litmus tests (marketer test, traceability test,
  "would Alex say it out loud" test) and violates zero banlist entries.
- Every mechanical claim has a source file behind it.
- Post builds clean under the scaffold (`bundle exec jekyll build`) and renders
  correctly at `/blog/quota-meter-burn-rate/` locally.
- Owner has reviewed and approved the draft. Publishing is a separate,
  owner-gated step — never commit or push from the writing session.
```

- [ ] **Step 2: Verify the brief is self-contained**

Check: every file path in the brief exists (`the-rollout-voice.md`, the 6 source files, the 2 asset files):
```bash
cd /Users/alexm/Repository/Codex-History
for f in docs/superpowers/the-rollout-voice.md docs/claude-usage-projection-freshness.md AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift AgentSessions/ClaudeStatus/ClaudeRunwayTokenActivityParser.swift AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift AgentSessions/CodexStatus/CodexRunwayModel.swift AgentSessions/CodexStatus/UsageDisplayMode.swift docs/assets/quota-meter-light.png docs/assets/quota-meter-runway.gif; do
  [ -e "$f" ] && echo "OK  $f" || echo "MISSING  $f"
done
```
Expected: 9 × `OK`. Fix any `MISSING` path in the brief before handing off.

- [ ] **Step 3: Commit (owner-gated)**

Ask the owner; on approval:
```bash
git add docs/superpowers/briefs/2026-07-09-quota-meter-post-brief.md
git commit -m "docs(rollout): writing brief for first post (Quota Meter burn-rate)" -- docs/superpowers/briefs/2026-07-09-quota-meter-post-brief.md
```

---

# Phase C — Publish (owner-gated, after the first post is approved)

### Task 7: Pre-publish build gate with the approved post

Runs only after the separate writing session's post has been reviewed and approved by the owner, and the approved file sits at `docs/_posts/<publish-date>-quota-meter-burn-rate.md`.

**Files:**
- Consumes: `docs/_posts/<publish-date>-quota-meter-burn-rate.md` (from the writing session), any new screenshot files under `docs/assets/`.

**Interfaces:**
- Produces: a green gate that Task 8's commit requires.

- [ ] **Step 1: Re-stamp the post date**

Confirm the `_posts` filename date is today's publish date (the URL slug ignores the date but the post's displayed date and feed timestamp use it). Rename if stale.

- [ ] **Step 2: Full gate — rerun every Phase A check**

Run:
```bash
SCRATCH="${TMPDIR:-/tmp}/rollout-build"
cd /Users/alexm/Repository/Codex-History/docs
BUNDLE_PATH="$SCRATCH/vendor" bundle exec jekyll build -d "$SCRATCH/site-final"
( cd "$SCRATCH/site-final" && find . -type f | sort ) > "$SCRATCH/final-manifest.txt"
diff "$SCRATCH/new-manifest.txt" "$SCRATCH/final-manifest.txt"
grep -c '\.md$' "$SCRATCH/final-manifest.txt"
xmllint --noout "$SCRATCH/site-final/feed.xml" && echo "FEED VALID"
xmllint --noout "$SCRATCH/site-final/sitemap.xml" && echo "SITEMAP VALID"
```
Expected: the manifest diff vs. Task 5's build adds ONLY `./blog/quota-meter-burn-rate/index.html` (plus any new screenshot files under `./assets/`); `feed.xml` and `sitemap.xml` already existed in both builds so they do NOT appear as additions (they are regenerated in place); `.md` count is 0; `FEED VALID` and `SITEMAP VALID` print. Then re-run Task 2 Step 3's byte-identity loop against `site-final` — expected `BYTE-DIFF FAILURES: 0`. Extend the loop's skip list to the non-source files: `feed.xml`, `sitemap.xml`, and the generated blog pages (`./blog/index.html` and `./blog/quota-meter-burn-rate/index.html`).

- [ ] **Step 3: Owner review of the rendered post**

Serve locally (`bundle exec jekyll serve`, URL `http://127.0.0.1:4000/agent-sessions/blog/`) and get an explicit GO from the owner on the rendered post, index, and nav.

### Task 8: Commit and push (requires explicit owner approval)

- [ ] **Step 1: Stage exactly the intended paths and show the owner**

```bash
git add docs/_posts/ docs/assets/<new-screenshots-if-any>
git status --porcelain ; git diff --cached --stat
```
Repo rule: verify `git diff --cached` contains only this feature's files before committing — never sweep the whole index.

- [ ] **Step 2: Commit and push (only on the owner's explicit "commit"/"push")**

```bash
git commit -m "feat(rollout): publish first post — Quota Meter burn-rate" -- docs/_posts docs/assets
git push
```
(If Phase A/B commits were deferred, they ship here too — same owner gate, same exact-path staging.)

### Task 9: Live verification on Pages

- [ ] **Step 1: Wait for the Pages build**

```bash
gh api repos/jazzyalex/agent-sessions/pages/builds/latest --jq '.status'
```
Repeat until `built` (typically < 2 minutes).

- [ ] **Step 2: Live checks — the whole contract, over HTTP**

```bash
base=https://jazzyalex.github.io/agent-sessions
curl -s -o /dev/null -w "landing: %{http_code}\n"      "$base/"
curl -s "$base/appcast.xml" | cmp - docs/appcast.xml && echo "APPCAST LIVE-IDENTICAL"
curl -s -o /dev/null -w "blog index: %{http_code}\n"   "$base/blog/"
curl -s -o /dev/null -w "post: %{http_code}\n"         "$base/blog/quota-meter-burn-rate/"
curl -s "$base/feed.xml" | xmllint --noout - && echo "FEED LIVE-VALID"
curl -s "$base/sitemap.xml" | xmllint --noout - && echo "SITEMAP LIVE-VALID"
curl -s "$base/sitemap.xml" | grep -q 'cockpit-mockup' && echo "FAIL: mockup leaked in sitemap" || echo "SITEMAP CLEAN (no mockup leak)"
curl -s -o /dev/null -w "guide: %{http_code}\n"        "$base/guides/codex-local-history.html"
curl -s -o /dev/null -w "CHANGELOG.md (want 404): %{http_code}\n" "$base/CHANGELOG.md"
curl -s -o /dev/null -w "mockup (want 404): %{http_code}\n" "$base/cockpit-mockup.html"
curl -s -o /dev/null -w "spec leak (want 404): %{http_code}\n" "$base/superpowers/specs/2026-07-09-the-rollout-blog-and-qm-post-design.md"
```
Expected: landing/blog/post/guide all `200`; `APPCAST LIVE-IDENTICAL`; `FEED LIVE-VALID`; `SITEMAP LIVE-VALID`; `SITEMAP CLEAN (no mockup leak)`; all three leak checks (CHANGELOG.md, mockup, spec) `404`.

- [ ] **Step 3: Sparkle smoke (owner)**

Owner runs "Check for Updates" in an installed Agent Sessions once — confirms the appcast still parses end-to-end. (Belt and suspenders on top of the byte check.)

---

## Self-Review

**Spec coverage:** `_config.yml` with url/baseurl/plugins/exclude → Task 2. `_layouts/blog.html` + `_layouts/post.html` reusing guide.css with `{% seo %}` → Task 3. `blog/index.html` at `/blog/` → Task 4. `_posts` first post → written externally per spec's own pipeline; brief in Task 6, publish in Tasks 7-8. Nav link on `index.html` + guide headers → Task 5. RSS `/feed.xml` (jekyll-feed) + `/sitemap.xml` (jekyll-sitemap) → Tasks 2/4/7/9. Byte-diff verification gate → refined per finding 5, implemented Tasks 2/5/7. Excluded specs 404 → Tasks 2 (local) + 9 (live). Distribution kit → delegated to the writing session via the brief (spec drafts it "alongside the post"). Draft→review→publish pipeline steps 1-4 → Tasks 6 → external session → 7 → 8. Out-of-scope items (CNAME, newsletter, other posts) → untouched. ✓

**Placeholder scan:** every created file's full content is present; the only intentionally-variable strings are the publish-date filename (`YYYY-MM-DD`, defined as the actual publish date in Tasks 6-7) and `<new-screenshots-if-any>` in Task 8, which the gate step enumerates. ✓

**Name consistency:** layouts `blog`/`post`; classes `post-list`/`post-meta`/`post-excerpt`/`post`/`post-back` defined in Task 3 CSS and used in Tasks 3-4 markup; scratch vars `SCRATCH`, `BUNDLE_PATH="$SCRATCH/vendor"`, manifests `baseline-manifest.txt`/`new-manifest.txt`/`final-manifest.txt` used identically across Tasks 1/2/7; post slug `quota-meter-burn-rate` consistent across Tasks 6/7/9. ✓

**Owner actions called out:** every commit (Tasks 1-6 gated, Task 8 explicit), screenshots (Task 6 brief / Task 7), rendered-post GO (Task 7), Sparkle smoke (Task 9), and the three open questions in finding 10.
