---
name: promo-outreach
description: Prepare, review, post, or track Agent Sessions promotion across X, Reddit, GitHub, directories, and community replies. Use for outreach candidate discovery, approval packets, public reply drafts, screenshot/link strategy, and response tracking. Enforces strict public-copy fit, owner-voice wording, and X's 280-character effective-length limit before posting.
---

# Promo Outreach

Use this skill for Agent Sessions public promotion and outreach. Keep promotion evidence-first, direct, and scoped to what Agent Sessions actually supports.

## Required Preflight

Before drafting or posting a public reply, write down these fields for the candidate:

- `affected_tool`: the product/tool that has the problem.
- `affected_tool_evidence`: exact words from the source post proving that tool is affected.
- `comparison_tools`: tools mentioned only as baselines or contrasts.
- `agent_sessions_support`: `supported`, `unsupported`, or `unknown` for the affected tool.
- `direct_capability_match`: the exact Agent Sessions feature that solves or helps the issue.
- `failure_class`: `history/search/resume`, `multi-agent-continuity`, `release-feature`, `performance/rendering`, `auth/subscription`, `install/setup`, `vendor-regression`, `competitor-launch`, or `other`.
- `link_destination`: `github`, `website`, `release-post`, or `no-link`.
- `media`: screenshot path or `skip`.

If any of `affected_tool`, `affected_tool_evidence`, `agent_sessions_support`, or `direct_capability_match` is weak or missing, downgrade to `support-first` or `hold`.

## Core Rules

- Use owner voice when the fit is real: "I built Agent Sessions..." not "a tool like Agent Sessions..."
- Linked replies need a literal fit: local history, transcript search, recovery, resume, source labels, multi-agent history, or a shipped release feature.
- Adjacent or support threads should be useful first and usually no-link.
- Do not post into hostile, security-sensitive, legal, drama, or direct-competitor launch threads.
- Do not overclaim support. Say "browse/search local transcripts" unless resume, analytics, live status, or usage tracking are verified for that agent.
- Verify the affected agent/tool before drafting. If a post names one agent only as a comparison baseline ("works in OpenCode", "unlike Claude", "for comparison"), do not classify that as the affected source. When the affected tool is unclear, hold the candidate or write a no-link clarification.
- Performance bugs, rendering bugs, crashes, auth/subscription issues, install failures, and vendor regressions are hold/no-link unless the author explicitly asks for a history/search/recovery workaround.
- Until a new dedicated social banner exists, do not rely on the Agent Sessions link-card image for X promotion. Attach the most relevant product screenshot for linked X replies when media upload works.
- Use screenshots when they prove the claim better than text; otherwise skip media and keep the reply short.

## Link Strategy

- Use the GitHub repo link when the reply already explains the product and the desired action is starring or checking source: `github.com/jazzyalex/agent-sessions`.
- Use the website link when the reader needs product context, screenshots, download/install path, or release notes: `jazzyalex.github.io/agent-sessions`.
- Use the X release-post link only for release-specific replies, such as Warp/WarpPreview 3.8.1.
- Use no link when the thread is only adjacent, support-first, skeptical, or the affected tool is unsupported.
- If a footer includes stars, refresh the star count immediately before posting.

## X 280-Character Gate

Every X reply or post must pass this gate before opening the composer.

- Final effective length must be `<= 280`.
- Count the final text, not the draft from the approval packet.
- Treat every URL or bare domain as 23 characters because X shortens links.
- Prefer `250-270` effective characters for replies with links or auto-added reply context.
- If the draft is over budget, shorten before posting. Do not let the X composer be the first validator.
- Screenshot attachments do not increase text budget.
- Drop star-count footers before dropping the core claim.
- Approval packets must include `X effective length: N/280` for every X draft that may be posted.

Use this check:

```js
function xEffectiveLength(text) {
  return text.replace(/https?:\/\/\S+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/\S*)?/g, "xxxxxxxxxxxxxxxxxxxxxxx").length
}
```

## Approval Packet Checklist

For each candidate include:

- Source URL.
- Fit score and category: `approved`, `support-first`, or `hold`.
- `affected_tool`, `affected_tool_evidence`, and `comparison_tools`.
- `agent_sessions_support` and `direct_capability_match`.
- Why Agent Sessions fits in one concrete sentence, or why it is only support-first/hold.
- `failure_class`.
- Risk and boundary, especially when recovery depends on local files existing.
- Final draft with `X effective length: N/280` when the target is X.
- Link strategy: GitHub, website, release post, no link, or wait for follow-up.
- Screenshot strategy: exact file path or `skip`. For linked X replies, default to a screenshot path until the social banner is replaced.

## Posting Discipline

- Post only approved candidates.
- Never batch more than 5 X replies without inspecting the results.
- Re-open each source thread immediately before posting and verify the source text still supports the candidate.
- If a source thread has a correction or reply that contradicts the candidate, stop and reclassify.
- After posting, record reply URL, posted text, screenshot used, timestamp, source URL, and baseline metrics in the tracker.
- If upload/media fails on a linked X reply, stop and report the blocker unless the user has explicitly approved text-only posting for that candidate.
- If a public reply is criticized as irrelevant or self-promotional, acknowledge the mismatch once and do not argue.

## Known Failure Patterns

- **Comparison inversion:** "OpenCode for comparison" means OpenCode may be the control, not the failing tool. Do not draft an OpenCode promo unless the post says OpenCode is affected.
- **Unsupported affected tool:** If the failing tool is Grok Build CLI, Aider, Cline, Roo, or another unsupported source, do not imply Agent Sessions can inspect its transcripts.
- **Performance bug bridge:** "Separate history browser helps" is not enough for a linked promo when the complaint is rendering, resize, startup, or reload performance.
- **Website conversion drag:** When asking for stars or using a star-count footer, GitHub is usually the better link than the website.
- **Image-card mismatch:** Until the social banner is replaced, linked X replies should attach a screenshot or use GitHub when product context is already clear.

## Repo References

- `docs/deep-dive/56-promotion-playbook.md`
- `docs/social/agent-sessions-outreach/REPLY_ENGINE_SPEC_2026-05-14.md`
- `Marketing/SCREENSHOTS.md`
