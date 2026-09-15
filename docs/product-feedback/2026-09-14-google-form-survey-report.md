# Agent Sessions feedback report and Google Form update plan

_Prepared 2026-09-14 against Agent Sessions 5.3 and the original 16-response dataset. Updated 2026-09-15 after the live form was simplified; the form now shows 17 responses._

## Executive decision

The form does not support a trustworthy feature-vote count anymore. It combines two different intake channels:

1. ten older, manually completed surveys with agent/feature/terminal checkboxes; and
2. six native in-app submissions that intentionally post only the free-text field plus app and macOS versions.

That is why the newest six rows have blank structured answers. They are not six users who selected no agents or features. Comparing the first ten checkbox totals with the last six responses would be false analysis.

The current actionable conclusion is:

- Do not reopen work for Saved Sessions, Hide Dock icon, onboarding performance, the old live-refresh scroll jump, or the broad March Claude-reliability comment. Those are delivered, owner-confirmed fixed, or superseded by later specific fixes.
- Do not call the September 14 startup report a current 5.3 defect. Both identical rows report Agent Sessions 5.1.1. Version 5.1.1 shipped August 31; 5.2 shipped September 9; the responses arrived at 3:07 PM on September 14; 5.3 was published later that day. Count the two identical rows as one reproduction lead against an outdated build.
- Finish and verify the already-written 5.3.1 retrieval-correctness plan before opening a separate “recent sessions” project. It already covers reproduced current defects in session arrival, active-search freshness, displayed-title search, fallback titles, and exact project selection.
- After 5.3.1, the best candidates for fresh validation are combined session-list filters and better at-a-glance session meaning. Ghostty and reopening an originating Cursor UI remain real capability gaps, but each has one old request and neither outranks retrieval correctness.

## Dataset

### Response shape

- Total Google Form rows: **16**.
- Manual full-form responses: **10**, submitted February 7 through June 24.
- Native in-app free-text responses: **6**, submitted July 24 through September 14.
- Rows with non-empty comments: **11**.
- Praise-only comments: **1**.
- Exact duplicate rows: **2**, both submitted September 14 at 3:07 PM with the same 5.1.1 text. They count as **one unique signal** unless independent respondent evidence appears.
- Unique actionable submissions after excluding the praise-only row and deduplicating the September pair: **9**.
- Distinct actionable themes inside those submissions: **11**, because two comments each contain two requests.

The channel split is confirmed by the product implementation. The native prompt asks one question, then `FeedbackSubmitter` posts only `entry.1909608576`. It appends the app version and macOS major version to that paragraph. It does not submit the form's agent, feature, terminal, or new/updating questions.

### Historical structured usage, not current adoption data

Only the first ten manual responses can be counted for these questions:

| Selection | Responses | Share of the 10 manual surveys |
|---|---:|---:|
| Session history | 10 | 100% |
| Search/filter | 10 | 100% |
| Analytics | 5 | 50% |
| Resume session | 4 | 40% |
| Usage/limit tracking | 4 | 40% |
| Agent Cockpit | 0 | 0% |
| Claude Code | 8 | 80% |
| Codex CLI | 5 | 50% |
| Gemini | 3 | 30% |
| OpenCode | 3 | 30% |
| Copilot CLI | 3 | 30% |
| Droid | 1 | 10% |
| OpenClaw | 0 | 0% |

These figures describe a February–June cohort and an obsolete questionnaire. They should not drive the current roadmap. The form omits Cursor, Pi, Kimi Code, Grok CLI, Hermes, Qwen Code, Devin CLI, and fx even though 5.3 browses those sources. It still asks about Agent Cockpit while 5.3 presents Quota Meter as the current surface, and its terminal list includes Ghostty but omits the shipped Warp integration.

## Version-aware disposition of every request

| Submitted | Reported version | Theme | Current disposition | Reason |
|---|---|---|---|---|
| Feb 9 | Not captured; form title said 2.11 | “Session bookmarks collection” | **Already existed; discoverability signal** | Saved Sessions shipped in 2.9 before this response. The request shows that the user did not discover or recognize it as bookmarks. 5.3 now places Saved inside the search field. |
| Feb 11 | Not captured | Hide Dock icon | **Delivered** | Hide Dock icon shipped in 3.1 on March 12 and received later safety and menu refinements. |
| Mar 9 | Not captured | Slow onboarding with a large history | **Closed as historical** | Owner confirms this is fixed. Do not use this response as evidence of a current problem. |
| Mar 16 | Not captured | Ghostty support | **Confirmed current capability gap; stale demand** | 5.3 terminal targets are Terminal, iTerm2, Warp, and WarpPreview. One six-month-old request is insufficient to outrank retrieval work. |
| Mar 16 | Not captured | More reliable Claude tracking | **Superseded; no current reproduction** | Later releases added and hardened OAuth, tmux, Web API/cookie, availability, and rate-limit paths. A new concrete failure should be triaged on its own evidence. |
| Mar 25 | Not captured | Slow main window and lost scroll position during Claude/subagent activity | **Delivered/superseded** | 3.9 fixed the session-list jump during live refresh. Later transcript and hierarchy fixes preserved selection and scroll in additional paths. Do not count this as open without a 5.3 reproduction. |
| Jul 24 | 4.6.4 | Recent sessions missing; only week-old sessions visible | **Old-version report; mapped to current retrieval plan** | The report predates 4.7, 5.0, 5.1, 5.1.1, 5.2, and 5.3. Current 5.3.1 planning already contains reproduced retrieval defects; finish that work before treating this as an additional feature request. |
| Jul 29 | 4.5 | Quick session summary or generated source title in the list | **Partially covered; revalidate after 5.3.1** | Current rows prefer explicit/source titles and 5.3.1 plans displayed-title search and fallback-title cleanup. There is still no cross-agent generated summary. Validate whether corrected titles solve the job before adding summarization. |
| Jul 29 | 4.5 | Jump back to the exact originating Cursor window/chat | **Confirmed unsupported boundary; discovery only** | 5.3 supports Cursor Agents Window and CLI transcripts. IDE sidepane chats without an Agent transcript are explicitly outside the supported history boundary. Current resume launches Cursor CLI; it does not deep-link to an originating editor chat. |
| Aug 6 | 4.6.4 | Combine project, date-range, and message-count filters; existing controls were not discoverable | **Partially covered; current gap remains** | Project selection and Analytics date/project controls exist. The session list does not have the requested combined date/message filter. The 5.3.1 plan fixes exact project selection but explicitly excludes a broader date filter or filter panel. Revalidate discoverability on the calmer 5.3 toolbar before designing more UI. |
| Sep 14, 3:07 PM, duplicated | 5.1.1 | Faster startup/caching; recent session unavailable for minutes | **One reproduction lead, not a confirmed current defect** | 5.1.1 was two weeks old and one public release behind at submission time. 5.3 shipped later that day. Reproduce on 5.3/5.3.1 with a large corpus before assigning roadmap priority. |

The July 29 “Only started adopting…” response is praise with no requested change and is excluded from prioritization.

## Current priority order

Freshness is evaluated by **reported app version first**, then submission date. An old-version report does not become current merely because it was submitted recently. Counts use deduplicated signals, and shipped fixes remove a request from the open ranking.

### 1. Complete the 5.3.1 retrieval-correctness patch

This is the only work backed by current reproduced defects. It addresses five concrete failures already measured in the current checkout: Antigravity cache reconciliation, active-search refresh, displayed-title search, Codex fallback-title noise, and exact project identity. It also absorbs the useful part of the July “recent sessions” and August project-filter feedback without inventing a second overlapping project.

### 2. Reproduce the 5.1.1 startup report on the current build

Status is **verify, not build**. Use a large real corpus and record:

- time to first persisted rows;
- time until the newest session is visible;
- provider-by-provider readiness;
- whether the delay is core hydration, full launch reconciliation, search freshness, analytics, or transcript work;
- app version/build and corpus sizes.

If 5.3.1 reproduces the multi-minute delay, promote it to P0 because it blocks the product's primary job. If it does not reproduce, close the form signal as fixed or version-specific.

### 3. Revalidate combined filtering after 5.3.1

One old response requested project + date + message count combinations and explicitly reported poor discoverability. First test the corrected exact project filter and 5.3 search-scope UI. If the job remains hard, design a compact structured filter surface. Do not count Analytics filters as satisfying session retrieval.

### 4. Test whether corrected titles solve “what is this session about?”

The desired outcome is rapid recognition, not necessarily AI summarization. After title-search parity and fallback cleanup land, test representative Codex, Claude, Cursor, Copilot, and OpenCode rows. Only pursue generated summaries if source titles and first-prompt titles still fail the recognition task.

### 5. Keep Ghostty and Cursor-origin reopening as demand-watch items

Both are confirmed absent. Each has one stale request. Before implementation:

- Ghostty: separate “launch a resume command in Ghostty” from live focus/presence features that currently depend on iTerm2.
- Cursor: verify that Cursor exposes a stable conversation/window identifier and supported reopen mechanism. Do not promise sidepane-chat coverage when 5.3 explicitly lacks those transcripts.

## What is wrong with the current Google Form

1. **Its title is version-bound:** “Agent Sessions v 2.11” is obsolete. Feedback intake must be evergreen.
2. **It mixes two products:** a public multi-question survey and a backend for the app's one-question prompt share one response table.
3. **Missing structured fields are ambiguous:** six app submissions look like users skipped every agent and feature choice.
4. **The agent list is stale:** it covers 7 names while 5.3 browses 14 active formats plus legacy Droid.
5. **The feature list is stale:** it omits Saved/Archived, Quota Meter, Session Info, Image Browser, export, and current search scopes, while retaining old Agent Cockpit wording.
6. **The terminal list is wrong for the product:** it offers Ghostty, which is not supported, and omits Warp, which is supported.
7. **Bugs, discoverability problems, feature requests, compatibility requests, and praise all land in one paragraph.** They cannot be routed or compared reliably.
8. **Version is embedded in prose:** this makes release-distance analysis and filtering brittle.
9. **No impact or frequency is captured:** “blocking every launch” and “nice someday” look the same.
10. **No duplicate handling exists:** the exact September pair must be detected manually. At the current volume, a normalized-text fingerprint in the response sheet is sufficient; this does not justify adding submission IDs to the app.
11. **No lifecycle fields exist:** the response sheet does not state reproduced/current, fixed, needs information, duplicate, planned, or declined.

## Google Form redesign

Redesign the **existing Google Form only**. No new backend, second form, app feature, or reporting system is needed.

### Title

> Agent Sessions Feedback

Do not put a product version in the title. The form should remain valid across releases.

### Description

> A short survey to help improve Agent Sessions.

Keep sign-in and automatic email collection off.

### Fields

1. **Which agents do you use regularly?**
   - Checkboxes.
   - Codex
   - Claude Code
   - Cursor
   - GitHub Copilot CLI
   - OpenCode
   - Antigravity
   - Other

2. **What features do you use?**
   - Checkboxes.
   - Session history and search
   - Resume session
   - Quota Meter / usage tracking
   - Session Info
   - Analytics
   - Saved / archived sessions
   - Other

3. **Email if you would like a reply (optional)**
   - Short answer; optional.
   - Do not use Google Forms' automatic “Collect email addresses” setting because it adds unnecessary identity/sign-in pressure.

4. **Bug report, feature request, or comment (optional)**
   - Paragraph.
   - Rename the existing `Feature Request/Comment` question in place. Do not delete or recreate it because the app submits to this field.

### Remove

- The new-user/updating question.
- The standalone terminal checklist.

The two simple checkbox questions provide enough structured context. Bugs, requests, terminal needs, and anything else can go in the free-form field.

### Closing section

> Thank you for your time and Github star!

### Implemented 2026-09-15

The live form now matches this design and remains on one page. The existing free-text question was renamed in place so the app's current field ID remains intact. No test responses were added to the real response dataset.

## Evidence used

- `docs/CHANGELOG.md`: release dates and shipped fixes, including Saved Sessions, Hide Dock icon, scroll preservation, Claude tracking, 5.1.1, 5.2, and 5.3.
- `docs/superpowers/plans/2026-09-14-5.3.1-retrieval-correctness-PLAN.md`: current reproduced retrieval defects and explicit exclusions.
- `AgentSessions/Onboarding/Models/FeedbackSubmitter.swift`: existing Google Forms endpoint, one-field submission, and version/macOS prose tag.
- `AgentSessions/Onboarding/Views/FeedbackPromptView.swift`: current native one-question UI and disclosure.
- `AgentSessions/Services/TerminalKind.swift`: current Terminal/iTerm2/Warp support boundary.
- `AgentSessions/CursorResume/CursorResumeCommandBuilder.swift`: current Cursor CLI resume behavior.
- `README.md`: current 5.3 supported-source inventory and product surface.
