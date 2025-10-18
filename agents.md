# Agent Sessions Agents Playbook

## Required workflow (for humans and agents)
1) Use Conventional Commits for every commit.
2) Add trailers to the commit:
   - Tool: Cursor|Codex|Xcode|Manual|Claude|Figma
   - Model: <model-id, e.g., gpt-5-thinking, o3-mini>
   - Why: <1 line if behavior/structure changed>
3) If you change architecture/data schema/build:
   - Add an ADR in /docs/adr/ using ADR-TEMPLATE.md.
   - Add a bullet under [Unreleased] in /docs/CHANGELOG.md.
4) If you change user-visible behavior:
   - Add a 1–2 bullet note in /docs/summaries/YYYY-MM.md.
 5) If you add, move, or rename Swift files (app or tests), you must also add/update them in the Xcode project (AgentSessions.xcodeproj): ensure PBXFileReference appears in the correct group and a PBXBuildFile entry is present in the app or test target Sources list. Failure to do this will break builds with “Cannot find … in scope”.

## Commit message examples
- feat(ui): add session title visibility in vertical layout
  Tool: Cursor
  Model: gpt-5-thinking

- fix(model): correct timezone handling for filename timestamps
  Tool: Cursor
  Model: gpt-5-thinking
  Why: Filename timestamps are in local time, not UTC

## Plan Mode

Plan Mode is a strict, analysis‑only interaction mode intended for early design and planning.

- How to enter Plan Mode
  - Any prompt that starts with `++` enters Plan Mode.
  - Any prompt that contains the phrase "plan mode" (case‑insensitive) enters Plan Mode.

- What's prohibited in Plan Mode
  - No file edits of any kind: do not create, modify, or delete files.
  - Do not run patching or write commands (e.g., `apply_patch`, `git commit`, code generation that alters the repo).
  - No schema/data migrations or build configuration changes.

- How to behave in Plan Mode
  - Act as a system architect, head of UX design, super‑senior developer, librarian, and business consultant.
  - Analyze the current context, identify assumptions/risks, and ask concise, high‑value clarifying questions when needed.
  - Produce a crisp plan: goals, constraints, approach options with trade‑offs, phased milestones, acceptance criteria, and open questions.
  - Where useful, outline interfaces, data contracts, and test strategy without altering files.

- Recommended output structure
  - Context and Goals
  - Constraints and Risks
  - Proposed Approach (with alternatives and trade‑offs)
  - Milestones and Deliverables
  - Acceptance Criteria
  - Open Questions / Clarifications

Exiting Plan Mode happens automatically when a subsequent prompt does not meet the entry criteria above. If a prompt asks to implement during Plan Mode, respond with a plan and explicitly note that implementation requires leaving Plan Mode.

## Commit Policy (Project‑Wide)

- No auto‑commits. This project uses an explicit approval model.
- The assistant must not commit unless the user says "commit".
- When the user says "commit", commit all uncommitted changes in one or more Conventional Commits as appropriate.
- Prefer a single cohesive commit when a set of changes is logically related; otherwise, group by feature or subsystem, but still only after the user's explicit "commit".
- Never assume partial commits are desired. If ambiguity exists, ask.

## Docs Style Policy (Strict)

- No emojis in any documentation. This applies to `README.md`, all files under `docs/`, issue/PR templates, and any other Markdown or text docs in the repo.
- Use clear headings and plain text. Prefer descriptive words over pictograms.
- Keep section titles short and consistent (e.g., "Requirements", "Install", "Usage").
- Avoid decorative characters that may reduce accessibility or searchability.

## UI/UX Implementation Rules

- Do not introduce layouts that overflow the default window size. When content can exceed the pane height (e.g., Preferences), wrap the main content in a vertical ScrollView and keep footer controls outside the scroll region so actions remain visible.
- Follow Apple HIG for toolbars and controls:
  - Use consistent control sizes within a toolbar. Group related items with spacers or separators; avoid crowding.
  - Keep segmented controls concise (2–5 segments) with clear on/off states; equal widths where appropriate.
  - Provide an accessible label, help tooltip, and keyboard shortcut where appropriate for every interactive item.
- Preferences panes:
  - Prefer compact row layouts (e.g., 2–3 columns per row using HStack/Grid) to reduce vertical height.
  - Avoid creating extra rows for single toggles when they can fit as a third column in an existing row.
  - Test at the app’s default Preferences window size to ensure all controls are reachable without resizing.
- If you add, move, or rename Swift files (app or tests), update AgentSessions.xcodeproj so new files are included in the correct targets; otherwise the build will fail.

## UI Design Language (HIG‑Aligned)

Use a consistent spacing scale and system colors. Do not hard‑code ad‑hoc paddings or margins in new views. When fixing UI, prefer adjusting shared tokens over one‑off values.

Spacing and sizing tokens (Swift):
- Window edge padding: `AnalyticsDesign.windowPadding = 20`
- Section spacing (between stacked cards/sections): `AnalyticsDesign.sectionSpacing = 16`
- Card spacing (between cards in a row): `AnalyticsDesign.cardSpacing = 12`
- Card internal padding: `AnalyticsDesign.cardPadding = 16`
- Corner radii: use the tokens defined alongside the feature (e.g., `AnalyticsDesign.cardCornerRadius`)

General rules:
- Apply `windowPadding` on both sides for all top‑level sections within a window. Sections should not set bespoke left/right paddings.
- Vertical rhythm comes from the parent stack’s `sectionSpacing`; avoid adding extra `padding(.top)` between adjacent sections unless there is a design reason shared across the product. Prefer updating the shared token instead.
- Labels or secondary text that describe a visualization must sit outside the plotting area with clear separation (e.g., footnote or caption under a heatmap). Do not overlay labels on the plot area.
- Use dynamic system colors and semantics (`controlBackgroundColor`, `labelColor`, etc.) so appearance follows Light/Dark and accessibility contrast preferences.
- If a feature’s layout requires a specific geometry to avoid crowding, prefer a fixed or minimum window size rather than shrinking content. Stable card sizes reduce layout churn when users resize windows.
- Follow Apple HIG for hierarchy: concise headers (`.headline`), body for key values, `caption`/`footnote` for supportive text. Maintain consistent typographic scale across cards.

Review checklist for PRs that touch UI:
- Edges and gutters match `windowPadding`.
- Vertical spacing between sections equals `sectionSpacing`.
- Card‑to‑card spacing in a row equals `cardSpacing`.
- Internal padding within cards equals `cardPadding`.
- Labels are not overlapping charts or interactive regions; they have dedicated space.
- Appearance adapts correctly to Light/Dark and high‑contrast settings.
