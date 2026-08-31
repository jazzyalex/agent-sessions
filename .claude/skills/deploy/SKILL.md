---
name: deploy
description: Use when shipping a release of Agent Sessions — bumping version, updating CHANGELOG, building, signing, notarizing, publishing appcast, and creating a GitHub release.
---

# Deployment Skill (Agent Sessions)

This skill is an agent-facing entrypoint that avoids duplicating the deployment runbook.

## Canonical Sources (Single Source of Truth)

- Runbook: `docs/deployment.md`
- Unified tool: `tools/release/deploy` (see `tools/release/deploy --help`)
- Recommended pre-release QA checklist: `docs/release/pre-release-qa.md`

If anything here disagrees with the runbook, follow `docs/deployment.md`.

## Workspace Policy (Hard Rule)

- Always run deployment from the user's current local repository checkout.
- Do not clone to temporary directories and do not switch to alternate worktrees as a deployment workaround.
- If the local worktree is dirty, stop and tell the user to clean the tree first (commit, stash, or discard), then continue in the same local repo.

## QA Gate (Mandatory — Run Automatically Before Deploy)

- **Always run QA automatically** before any bump/release/verify step, unless the user explicitly says to skip it (e.g. "skip QA", "no QA").
- Do not ask whether to run QA — just run it.
- QA execution order:
  1. **Scope** — `git log --oneline --decorate -n 30` and `git diff --name-only <LAST_TAG>..HEAD`; identify high-risk areas.
  2. **Build** — `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
  3. **Full test suite** — `./scripts/xcode_test_stable.sh`
  4. **Targeted tests** — run suites for touched high-risk areas (session parsing, usage tracking, onboarding, etc.)
  5. **Warnings sweep** — flag any new actionable warnings in build output.
  6. **Manual smoke reminder** — list the manual steps from `docs/release/pre-release-qa.md` §3–4 and ask the user to confirm GO/NO-GO after completing them.
- If automated gates fail → stop, report failure, do not proceed to bump/release.
- If user says "skip QA" or "no QA" → proceed without running, note it was skipped.

**Test count.** QA reads the authoritative pass count from the `.xcresult` bundle (stdout
reports per-bundle totals and this scheme has two — it under-reports) and compares it to
`tools/release/test-count-baseline.txt`. A drop **warns and continues**, deliberately: it
does not block a release. So the warning has to actually be read — a deleted suite still
exits 0 from xcodebuild, and this line is the only thing that says so. When the count
changes for a real reason, update the baseline file in the same release.

## Before Starting (Ask the User)

1. Target version (`X.Y` for major/minor releases, `X.Y.Z` only for patch releases; never ship `X.Y.0`)
2. Any headline changes (new agents, major features) that must be reflected in `docs/CHANGELOG.md`
3. Whether this is a major release that requires onboarding updates
4. Public copy updates needed for README/GitHub Pages (major changes to highlight, renamed features, or outdated wording to fix)

**Do NOT ask about QA status** — QA always runs automatically as part of pre-deploy (see QA Gate above).

## Public Copy Update (Required for All Releases)

### Always update (every release)
- `README.md` download link: `v{VERSION}/AgentSessions-{VERSION}.dmg` and label `Download Agent Sessions {VERSION} (DMG)`
- `README.md` Option A download link (second occurrence under Install section)
- `docs/index.html` download button URL and label
- `docs/index.html` version meta-line (`Version {VERSION} · Free & open source · No telemetry`)

### Do NOT version-pin the site meta descriptions

`docs/index.html`'s `description`, `og:description` and `twitter:description` are
**deliberately version-agnostic** as of the 2026-08-29 SEO work. This checklist used to
demand "mention current version + key change" there, which is how the homepage description
reached 541 chars reading "Version 5.0 makes every agent a plug-in adapter…" — past the
~155-char SERP budget, and stale the day after every release.

Leave them alone. If the product's positioning genuinely changes, rewrite them on their own
merits and keep the budget: **title ≤60, description ≤155.** Adding a version string is the
one edit that is always wrong. See the `reference-docs-site-seo-conventions` memory.

### Update for minor/major or user-visible feature releases
- `README.md` "What's New in X.Y" section: update heading to new version, rewrite TL;DR and Highlights to reflect this release's key changes (do not keep old version's copy)
- `docs/index.html` hero/feature copy if features were renamed or new agents added

### Never add
- Versioned "What's New in X.Y" section to `docs/index.html`
- Detailed release notes to README or website (those live in `docs/CHANGELOG.md`)

## Never Announce a Bug the User Never Had (Hard Rule)

**A fix to a feature that ships in this same release is not a Bug Fix. It is development.**

When a feature is new in X.Y, every defect found and fixed in it before X.Y shipped was
never in anyone's hands. Listing those under "Bug Fixes" invents a history of breakage
users never experienced, and buries the actual feature under a list of things that sound
broken. Ship the feature; the fixes are part of it.

Before writing any Bug Fix entry, ask: **which released version had this bug?** If the
answer is "none — the code is new in this release", the entry does not exist. Fold
anything user-visible into the feature's own Highlight instead.

Worked example (4.8, Grok CLI's first release):
- ❌ "A Grok session shows the title its own sidecar records" — Grok shipped in 4.8; no
  user ever saw the wrong title.
- ❌ "Grok transcripts open with content in them" — same.
- ❌ "A Grok session's message count matches its transcript" — same.
- ✅ "Grok CLI is the eleventh current agent source…" — the Highlight, which already says
  transcripts, images, Analytics and resume work.

Mixed entries need splitting, not deleting: a fix spanning shipped **and** new sources is
real for the shipped ones. Describe it in terms of those, and drop the new source from the
list. In 4.8 the CLI PATH-masking fix covered Cursor, Kimi and Pi (all shipped) plus Grok
(new) — it stayed, naming only the three.

This applies identically to `docs/CHANGELOG.md`, the Sparkle notes, the GitHub release
body, and the README "What's New". The changelog is the source all of them derive from, so
fix it there first.

### After pushing
- Verify GitHub Pages reflects updated `docs/index.html` (check the download button and version meta-line; the meta descriptions should read the same as before the release)

## Pre-Deploy Checklist (Run Before Bump)

- [ ] `docs/CHANGELOG.md` `[Unreleased]` section has full, accurate content for this release (this is the only changelog — root `CHANGELOG.md` is a pointer to it, not a copy to sync)
- [ ] Every Bug Fix entry names a defect that existed in a **released** version — no fixes to features shipping in this same release (see "Never Announce a Bug the User Never Had")
- [ ] In-app What's New has an entry for this version in `AgentSessions/Onboarding/Models/WhatsNewCatalog.swift` — both a `teasers` line and a `bundled` array. `hasContent` goes true on the auto-generated new-provider row alone, so a forgotten release still shows the card, just with one generic line and no teaser. Do not author a row for a new source by hand: `providerHighlights(for:)` generates it from `versionIntroduced`, and authoring it again shows it twice.
- [ ] README.md download links updated to new version (both occurrences)
- [ ] README.md "What's New" section updated to new version heading + rewritten highlights
- [ ] `docs/index.html` download button URL, label, and version meta-line updated
- [ ] `docs/index.html` meta descriptions left **unchanged** — they are version-agnostic on purpose (see "Do NOT version-pin the site meta descriptions")
- [ ] All above files committed before running `deploy bump` (or bump will overwrite)

## Sparkle Notes Are Short and Fun (Hard Rule)

Sparkle notes appear in a small update window. Nobody reads prose there. The 5.0 notes
shipped as full changelog paragraphs and had to be republished after the fact — don't
repeat that.

- **Highlight**: 2–4 sentences, hard max. Lead with the change, keep one concrete number
  if there is one, cut everything a curious reader can find in the changelog.
- **Feature / Bug Fix bullets**: 1–2 sentences. One for what changed, at most one for
  why it was wrong before. A good bug-fix line can be a single sentence
  ("Five agents used to skip it silently.").
- **Whole notes**: aim under ~250 words. If the preview scrolls, it's too long.
- **Tone**: dry fun is welcome — "takes no for an answer", "Bring the agent you use".
  Personality yes, marketing-speak no, emoji never.
- The full detail lives in `docs/CHANGELOG.md`; the notes may compress it freely.
  If an entry can't be compressed without losing the point, the changelog entry is
  overweight — tighten it there first (changelog entries also don't need to be essays).
- Links in changelog entries that feed the notes must be **absolute URLs** — relative
  links break in the appcast and the GitHub release body.
- To republish notes after a release: edit `docs/CHANGELOG.md`, then
  `python3 tools/release/sparkle_release_notes.py --version <V> --changelog docs/CHANGELOG.md --appcast docs/appcast.xml --github-url <release-url> --lint --out-text /tmp/notes.txt`,
  then `gh release edit v<V> --notes-file /tmp/notes.txt`, commit and push the appcast.

## Sparkle Release Notes (Approval Gate)

- The release pipeline generates **structured Sparkle notes** from `docs/CHANGELOG.md`:
  - Highlights or grouped current-release changes
  - Other changes (summary)
  - Reminder from the baseline release (for patch releases: `A.B`)
- During `tools/release/deploy release <VERSION>`, the deploy script prints a **Sparkle release notes preview** after build/sign/notarization and appcast validation.
- Treat the preview as user-facing product copy, not raw commit history:
  - Lead with the headline change the user should care about.
  - Do not include internal cleanup, validation fixes, or pre-release stabilization as “Bug Fixes” if users never received that broken behavior.
  - If the preview is misleading, stop and edit `docs/CHANGELOG.md` before publishing.
- If `SKIP_CONFIRM` is not `1`, it will pause and ask for approval before publishing (pushing appcast, updating Homebrew, updating the GitHub release).
- `SKIP_CONFIRM=1` requires `RELEASE_NOTES_REVIEWED=1` at the appcast publish gate; set it only after manually inspecting the Sparkle preview or for a rerun whose notes were already reviewed.
- The notes generator fails before publishing if notes contain obvious internal/process wording or put Bug Fixes ahead of a headline section.
- GitHub Release notes must use the same curated/linted notes as Sparkle, not raw commit history or raw changelog extraction.
- If the current release has no structured bullets, the generator adds a fallback highlight: `Small bug fixes and stability improvements.`

## Standard Workflow (Use the Unified Tool)

```bash
tools/release/deploy changelog [FROM_TAG]
tools/release/deploy bump [patch|minor|major]
git push origin main
tools/release/deploy release <VERSION> [--dry-run]
tools/release/deploy verify <VERSION>
```

## Failure Handling

- First stop: `docs/deployment.md` → Troubleshooting, logs, and rollback guidance.
- Rollback only after reviewing logs: `tools/release/rollback-release.sh <VERSION>`.

### Read the real exit code, and check what actually published

Two traps, both hit during 5.1.1:

- **Do not wrap the release in `; echo "EXIT: $?"`.** The wrapper's own status is what the
  caller sees, so a pipeline that correctly exited 4 was reported as 0 and briefly looked
  like a tooling bug. Run `tools/release/deploy release <V>` on its own and read its status.
- **A completed run is not a published release.** Confirm against the world, not the log:

  ```bash
  gh release view v<VERSION> --json tagName,isDraft,assets
  git ls-remote --tags origin v<VERSION>
  grep -n "sparkle:shortVersionString" docs/appcast.xml
  ```

  Then `tools/release/deploy verify <VERSION>` for the full check. A failure before the
  publish steps leaves nothing public — no release, no tag, appcast unchanged — which is
  the state to expect after an aborted build.

### Watching a long run

The release log embeds the entire QA test output, so a bare keyword grep matches **test
names**, not events — "Aborted", "Homebrew" and "rollback" all produced false alarms during
5.1.1. Anchor on the script's own line markers (`^==> `, `^✅ `, `^ERROR: `) and run the
pattern against the live log before trusting it. Note also that `ERROR: Release QA stamp is
not valid` is expected and self-heals whenever HEAD moved after `deploy qa` — it re-runs QA
rather than failing. When matching newest-file-by-glob (`/tmp/notarization-<V>-*.log`),
guard on mtime or you will read the previous run's artifacts.
