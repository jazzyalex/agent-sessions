# Site chrome unification — landing-page header + style everywhere

**Date:** 2026-07-18
**Status:** Approved (Approach A), implementing
**Scope:** `docs/` GitHub Pages site only. No app/Swift changes.

## Problem

The site has two visual languages:

- **Landing** (`docs/index.html`) — self-contained inline `<style>`: Apple-style
  design tokens (`--bg`, `--ink`, `--blue`…), a sticky blurred `.nav` header,
  full light **and** dark mode, pill buttons, card grids.
- **Guides + The Rollout blog** — share `guides/guide.css`: a plain non-sticky
  GitHub-docs header (40px icon + `Agent Sessions` heading left; "The Rollout •
  macOS • Open Source ⭐" right), `#f6f8fa` bg, `#0969da` links. The blog layers
  `blog/blog.css` which *adds* dark mode; the guides are **light-only**.

Goal: make the landing page's header + visual style the standard across the
guides and the blog.

## Decisions

- **Depth:** Chrome + tokens. Adopt the landing's sticky nav header, footer
  treatment, color/font tokens, and dark mode site-wide. Keep the existing
  readable guide/blog **article body** typography (headings, prose, code, notes,
  meta cards) — retuned to the tokens, not restructured.
- **Sub-page nav:** Simplified — brand/home + `The Rollout` + `GitHub ★`. (The
  landing keeps its fuller nav: Features · Quota Meter · Guides · The Rollout ·
  GitHub.)
- **Footer:** Keep the lean one-line sub-page footer, restyled with tokens
  (bg-sunken band + hairline top border) to match the landing footer's
  treatment — not a clone of the landing's multi-paragraph disclaimer.
- **Landing stays untouched.** It is the reference. Its tokens/nav/footer are
  reproduced in `guides/guide.css`. Accepted trade-off: token values live in two
  places, so a future landing redesign needs a matching `guide.css` edit. This
  keeps zero risk on the most important page. (Full DRY would require Jekyll-ifying
  the static guides + extracting the landing CSS — rejected as out of scope.)

## Approach A (chosen)

Rework the **already-shared** stylesheet + swap the header markup. No `<link>`
href changes anywhere; `guide.js` reused as-is (nav keeps its `#github-stars`
IDs).

### Files changed

1. **`docs/guides/guide.css`** — the real work. Becomes the unified system:
   - `:root` tokens (light) + `@media (prefers-color-scheme: dark)` tokens,
     copied from `index.html` so values match exactly.
   - Base `body` / `a` on tokens.
   - `.nav` sticky blurred header + `.nav-inner`, `.nav-brand`, `.nav-links`,
     `.nav-star`, `.gh-star-icon`, copied from `index.html`.
   - Existing content classes retuned to tokens: `.guide-shell`, `.eyebrow`,
     `h1/h2`, `.lede`, `.button-row`, `.btn(.primary/.secondary)`, `.note`,
     `.boundary`, `.meta-grid`, `.meta-card`, `pre`, `code`, `.sources` —
     hardcoded `#fff`/`#d0d7de`/`#57606a` → `--bg-elev`/`--hair(-strong)`/`--ink-*`
     so dark mode works.
   - `.site-footer` → full-width `--bg-sunken` band with hairline top border.
   - Guides gain dark mode for free.

2. **`docs/blog/blog.css`** — trim to blog-listing/post specifics only
   (`.post-list*`, `.post-meta`, `.post-excerpt`, `article.post*`, `.post-figure*`,
   `.post-back`), tokenized. **Delete** its bespoke `@media dark` block (now global
   via tokens in guide.css).

3. **`docs/_layouts/blog.html`** — replace `<header>…</header>` with the simplified
   `.nav`. One edit covers the blog index + every post.

4. **`docs/guides/*.html` (6 files)** — replace each identical inline
   `<header>…</header>` with the same simplified `.nav`.

### Unchanged
`docs/index.html`, `docs/guides/guide.js`.

## Verification

- Build the site locally (`bundle exec jekyll build` in `docs/`) — no errors,
  guides + blog + index all emit.
- Visual check in light and dark: nav is identical (sticky, blurred, small icon +
  wordmark, The Rollout + GitHub★) on landing, a guide, the blog index, and a
  post; guide/blog bodies render correctly in dark mode; footers match.
- Landing page byte-identical (untouched).
