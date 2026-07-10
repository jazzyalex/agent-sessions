# Onboarding Rework — Design Spec

**Date:** 2026-07-09
**Status:** Draft for review
**Owner:** Alex (jazzyalex)

## Problem

The current onboarding (`AgentSessions/Onboarding/`) conflates three different jobs into one blocking modal sheet (min 820×700, `interactiveDismissDisabled`):

1. **Setup** — agent toggles, Quota Meter opt-in (the only real decisions).
2. **Announcement** — "what's new" slides, re-shown on every minor version bump.
3. **Education** — Power Tips (15 screens of tips at minute zero).

Because all three share one surface, the modal is long, fires on every release, and users can't articulate what it's *for*. Additionally, the feedback funnel (Google Form linked from the last slide) has produced ~10 responses all-time — audit showed the form is short and low-friction, but it's asked at the wrong moment (minute zero, before the user has used anything), in the wrong vessel (stale version-stamped Google Form), with the wrong questions (inventory the app can detect itself).

## Goals

- First-run onboarding completes in ~15 seconds and never re-appears.
- Updates never show a blocking modal.
- A reusable, non-blocking announcement surface exists (release highlights now; promo slots for own/3rd-party products later).
- Feedback volume increases by an order of magnitude via a native, well-timed, one-question ask.
- No telemetry. No new background network calls. All sends are explicit user actions.

## Non-goals

- No progressive checklist / gamified setup (rejected as overkill for two decisions).
- No remote-config promo network in v1 (promos ship bundled per release; remote static JSON is a possible v2).
- No changes to Sparkle release notes.

## Design

Four surfaces, each with one job:

### 1. First-run setup (replaces full tour)

**One screen**, shown once on fresh install (existing `defaultIsFreshInstall` check on `index.db`). The app serves two audiences — session-history users and Quota-Meter users (some install only for the meter) — so the screen presents **two equal value blocks**, no persona quiz, no branching:

- **Block A — Your sessions:** app icon + "N sessions found" animated count (the history aha moment) + agent toggle grid (existing `AgentToggleTile` grid, unchanged behavior).
- **Block B — Quota Meter:** a **looping marketing GIF** of the real meter in action (`Marketing/v40-quota-meter-runway-both-agents-trimmed.gif` — the original was trimmed to frames 0–184 to drop a Control Center popup artifact and the static toolbar tail; bundled as an app asset and animated via an `NSImageView`-backed representable) plus a single **"Enable Quota Meter"** toggle (default on; on = both `codexUsageEnabled` and `claudeUsageEnabled` true, off = both false; reads as on if either is enabled). No per-provider toggles, no caption. The GIF is a canned demo, deliberately **not** a live preview — a fresh install has no burn history yet, so a live meter would render the empty "No active burn" state and undersell the feature; the GIF always shows the rich runway/burn-rate story. Reduce-motion shows the first frame static.
- Primary button: **Start Exploring**. No Back/Next, no progress dots, no Later.
- Footer line (small, secondary): "Tips live in Help → Power Tips."

Visual rule: neutral cards with the app's blue as the single accent; green/orange reserved for semantic meter states. No purple.

Deleted from first-run: Quota Meter marketing slide, Power Tips slide, Analytics slide, Feedback/Support slide, restore-archived-Claude slide. The sheet becomes dismissible (Esc = same as Start Exploring; completion is recorded either way).

### 2. What's New panel (replaces update tour)

On version bump (major.minor change, existing `onboardingLastActionMajorMinor` logic), **no modal**. Instead:

- A **dismissible card** at the top of the session list: "✨ What's New in X.Y" + one-line teaser + "See what's new" / close button. Dismiss = recorded for that version, never re-shown.
- Clicking opens a **compact panel** (sheet or popover, Esc-dismissible, ~480pt wide) containing an ordered list of item rows:
  - 2–4 **release highlights** (icon + title + 1–2 lines; reuse `FeatureRow` visual language).
  - 0–1 **tip** row (drawn from the Power Tips catalog).
  - 0–1 **promo slot** (see §4).
  - 0–1 **feedback ask** row (see §3), shown per the timing rules there.
  - If a version has no content at all (no authored items, no new-provider items), the panel shows a friendly "You're all caught up" empty state rather than a bare header — so **Help → What's New** always does something visible.
- Content is a bundled per-release catalog (`WhatsNewCatalog`, items instead of screens). Auto-generated "New agent support" highlights come from `WhatsNewCatalog.providerHighlights` (keyed off `SessionSource.versionIntroduced`).
- Also reachable anytime via **Help → What's New**.

### 3. Native feedback ask (replaces Google Form funnel)

- **Trigger:** one-time prompt shown only after real usage — earliest of: 10 sessions opened OR 14 days since install; never on first run. Appears as a row in the What's New panel and/or a small dismissible card in the session list (same slot the What's New card uses; never both at once, What's New wins).
- **Card ✕ = soft dismiss.** Dismissing the feedback *card* with its ✕ hides it for the rest of that launch only (in-memory) and does **not** advance the permanent decline lifecycle — an accidental ✕ never costs a strike; the card can return next launch while the ask is still due.
- **UI:** one question — *"What's the one thing you wish Agent Sessions did better?"* — native multiline text field + optional email field (placeholder "optional, if you'd like a reply") + Send / Not now. The prompt's **"Not now"** is the explicit decline: ask once more after the next major.minor update, then never again.
- **Transport:** a single `application/x-www-form-urlencoded` POST to the existing Google Form's `formResponse` endpoint, fired **only** when the user presses Send. This reuses infrastructure the owner already has (no server to run); responses land in the form's linked sheet. The user's note goes in the form's free-text paragraph field, with a one-line context tag appended (app version, macOS major version, and the optional reply email). The UI states this plainly ("Sent to the developer via Google Forms, tagged with your app and macOS version. No tracking."). The form URL + entry field are documented constants so the owner can repoint at a dedicated form later.
- **Fallbacks** shown as small links under the field: "Open a GitHub issue" · "GitHub Discussions".
- **Google Form:** retire from the app. If kept alive externally (README/website), retitle evergreen ("Help shape Agent Sessions — 30 seconds, no sign-in"), cut to 2 questions ("What made you try it?" + "What do you wish it did?"), move the star-ask to the post-submit page.
- Sponsor/star asks move out of onboarding entirely: a "Support the project" item may appear occasionally in the What's New panel (max one per release, never alongside the feedback ask).

### 4. Promo slots

- A promo is a What's New item row: icon/thumbnail + title + 1–2 lines + external link, **always labeled** with a small "Promo" tag.
- v1: bundled in the per-release catalog (compile-time). v2 option: fetch a static `announcements.json` from the same host as the Sparkle appcast (a host the app already contacts), cached, no identifiers sent — preserves the no-telemetry story.
- Rules: max one promo per panel; never on first-run; dismissing the What's New card dismisses the promo with it.

### Power Tips

Unchanged as a catalog; remains at Help → Power Tips. Removed from first-run and update flows except as the single optional tip row in the What's New panel.

### Cross-surface discoverability (two-audience rule)

The app tracks locally (UserDefaults counters, no telemetry) which halves the user actually touches: main-window opens vs. Quota Meter/menu-bar-meter use. The What's New panel's single tip slot targets the gap:

- History-only users → a Quota Meter tip.
- Quota-only users → a "your sessions are searchable" tip; if they enable the meter but rarely open the main window, the tip is the hide-Dock-icon / menu-bar-only mode.
- Both → a regular power tip.

No separate quota-only launch mode in v1.

## Architecture / code impact

- `OnboardingCoordinator` shrinks: fresh-install path presents the single setup screen; update path publishes a "what's new available for X.Y" flag instead of presenting a sheet. Version bookkeeping (`onboardingLastSeenAppMajorMinor`, `onboardingLastActionMajorMinor`) is reused; new key for What's-New-dismissed version and feedback-ask state.
- `OnboardingContent` becomes two catalogs: `SetupScreen` (trivial) and `WhatsNewCatalog` (`[WhatsNewItem]` per major.minor; item kinds: `highlight`, `tip`, `promo`, `feedbackAsk`, `support`).
- `OnboardingSheetView` (~2,270 lines) is decomposed: `FirstRunSetupView`, `WhatsNewPanelView`, `WhatsNewCard`, `FeedbackPromptView`, plus the shared components (`FeatureRow`, `TipBox`, `AgentToggleTile`, palette) extracted to `Onboarding/Components/`. The 10-indexer fan-in stays only where counts are shown (first-run screen).
- New `FeedbackSubmitter` (single async POST, explicit user action, no retries queue — failure shows "couldn't send, try GitHub" inline).
- Session-list top-card slot: one lightweight container view that can host either the What's New card or the feedback card.

## Error handling

- Feedback POST failure: inline error + GitHub fallback links; text is preserved in the field.
- Missing What's New catalog for a version: show auto-generated items only (new providers), or skip the card entirely if there are none.
- All dismissed states persist in `UserDefaults` (existing `OnboardingDefaults` pattern).

## Testing

- Extend `OnboardingCoordinatorTests`: fresh-install → setup once; version bump → What's New flag (not sheet); dismissed version never re-flags; suppression matrix carries over.
- New tests: feedback-ask trigger timing (sessions-opened / days-since-install / not-on-first-run / re-ask-once rule), What's New catalog assembly (highlights + auto provider items + at-most-one promo).
- `FeedbackSubmitter` tested against a mock endpoint (form body carries the note + context tag in the paragraph field; `+`/space encoding is unambiguous; email tag omitted when blank).
- Manual QA at feature-complete (per repo convention): fresh install, minor-bump update, feedback flow, Esc behavior.

## Rollout

1. Ship surfaces 1–3 together in one minor release (the What's New panel for that release announces the new onboarding itself — good dogfood).
2. Promo slot (§4) lands with the first release that has something to promote; the item kind exists from day one.
3. Retire the Google Form link from the app in the same release.
