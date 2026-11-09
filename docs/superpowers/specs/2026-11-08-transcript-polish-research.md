# Transcript polish: prior art and user need

Date: 2026-11-08. Pre-spec research for the backlog entry "Transcript polish: code and diff
highlighting, better layout" (`docs/backlog.md`, Transcript UI). No spec yet.

Sources:
- Source code, shallow clones read on 2026-11-08 (nothing run):
  - OpenCode `anomalyco/opencode` @ `dc71d5f9`, `packages/session-ui/src/`
  - Codex CLI TUI `openai/codex` @ `4e4767ff`, `codex-rs/tui/src/` (Codex desktop is closed source)
  - Claude Code History Viewer `jhlee0409/claude-code-history-viewer` (CCHV, Tauri + React)
  - AgentsView `kenn-io/agentsview` (Svelte + Go)
  - claude-code-log `daaain/claude-code-log` (Python, static HTML)
- Window captures of Codex desktop (in ChatGPT.app) and OpenCode desktop, kept local in
  `Marketing/transcript-prior-art/shots/` (gitignored: they show the owner's sessions).
- GitHub issues and discussions of `jazzyalex/agent-sessions` (52 issues, 6 discussions),
  `Marketing/STATUS.md`, README and site copy.

Not covered:
- The Claude desktop app could not be captured. The capture tool cannot operate Claude's own
  window. The owner sees that UI every day in the Code tab.
- Expanded diffs and tool rows in Codex and OpenCode. Both apps stop redrawing in the
  background, and full-screen control was not approved in time. Source code covers these
  details instead.

## 1. Prior art

### How each app shows one agent turn

| | Codex desktop | OpenCode desktop | Codex TUI | AgentsView | CCHV |
|---|---|---|---|---|---|
| User message | right-aligned black bubble; long text clipped, "Show more" | right-aligned filled bubble; folds past 12 lines, shows 8 | `›` marker on a faint fill | role accent color | header + body |
| Agent work between prompt and answer | folded into one line: "Worked for 2m 57s ›" | each tool is a muted one-line row; consecutive tools fold into a group with a sticky header | "Explored" groups merge read/list/search | consecutive tools fold into a group; "focused" mode hides them | one card per tool |
| Tool row (collapsed) | icon + one muted line ("Ran git status …") | "Shell" + command as dim subtitle; args chips for grep | `• Ran cmd`, green/red bullet by exit code | chevron + name + first-line preview (100 chars) | icon + title + id badge |
| Long output | n/a in capture | max 240 px, scrolls | 3 lines, then `… +N lines` | 20-line preview, then max 300 px | 15 lines, then "show more" |
| Errors | — | red left bar; failure taken from exit code even if the tool "completed"; error rows start collapsed | red bullet | outcome dot | — |
| Thinking | — | muted gray text; row "Thought · 12s" | dim italic | collapsible block | italic first line, 100 chars |
| Turn footer | — | "Build · model · 9s" + copy | "Worked for 1m 12s" | time + mono token summary; model only when it differs | time; tokens in a popover |
| Files changed | side panel "Changes +12 −0"; "Show N more files" card | "1 Changed file +42 −1", per-file accordion | `• Edited path +N −M` | — | "Recent Edits" view |

### Diffs

| | Layout | Line numbers | Word-level | Colors | Size rule |
|---|---|---|---|---|---|
| OpenCode | unified (split optional), bars | yes | yes | red/green line tint 5% light / 10% dark; word emphasis 20% / 40% | word diff and tokenizing off above 500,000 chars; 20-line context expanders |
| Codex TUI | unified | yes | no | GitHub light `#dafbe1` / `#ffebe9`; dark `#213A2B` / `#4A221D` | 3-line preview per file; full diff in the pager |
| AgentsView | unified, plain `<pre>` | no | no | green/red at 10%, blue hunk header | cut at 200 lines + "… (N lines total)" |
| CCHV | split by default, unified toggle | yes | via a second mode | library defaults | `max-h-96` scroll box |
| claude-code-log | unified | — | yes (`<mark>`) | GitHub light palette | — |

### Code blocks

- Everyone except AS highlights fenced code:
  - OpenCode: Pierre highlighter in a web worker, with a theme built from app colors.
  - Codex TUI: syntect.
  - AgentsView: Shiki, one theme.
  - CCHV: Prism, light and dark themes.
- Everyone guards against size:
  - CCHV: 50,000 chars.
  - Codex TUI: 512 KB, 10,000 lines or a 4 KB line.
  - OpenCode: 500,000 chars.
- OpenCode puts the copy button beside the code block, not inside it, so selecting text never
  picks up the button. The button shows on hover.

### History-browser features in the two viewers

- Prompt jump:
  - CCHV: ⌥↑ / ⌥↓.
  - AgentsView: ⇧J / ⇧K.
  - AS already has You ▲▼.
- Find: a match-tick rail beside the scroll bar (AgentsView). A search hit opens a collapsed
  block without changing its saved state (CCHV and AgentsView).
- A "focused" mode that shows only prompts and final answers (AgentsView). CCHV has
  per-kind filter toggles.
- Both viewers had to separate injected context from typed prompts. This is the same problem
  as AS commit `55aec3c4`.

### What AS has today (main @ 8305a24b)

- Markdown cards (`AgentSessions/Services/RenderedBody.swift`):
  - inline-code chips;
  - fenced code blocks drawn on a card background;
  - tables.
- No syntax highlighting in code blocks.
- JSON coloring only in the plain view (`TranscriptPlainView.swift`, `jsonSyntaxHighlightRanges`).
- 6.4 tool view: one row per call with L0/L1/L2 detail. Diffs show as monospaced text with no
  color and no line numbers.
- Origin rows (55aec3c4), Context toggle, role filters, find, You ▲▼, Copy, Export Markdown.

## 2. User need

The evidence is small: about 25 people reported the 52 issues, and most are early users.

| Task | Distinct users | Evidence |
|---|---|---|
| Find a past session | ~11 | #9, #19, #73 search; #13, #26 titles; #49, #87, #3, #43, #44 list noise |
| Resume or continue | ~6 | #25, #16, #88, #58, #49, #87 |
| Re-read what happened | ~6 | #6 tool calls unreadable (empty `&gt;` gaps); #8, #12 missing messages; #17 slow open; #5 confusing view |
| Share or export readable text | 2 | #29 filtered Markdown export (shipped, "Works, thanks"); #80 readable archives, "I don't care much about the format" |
| Copy code out | 0–1 | #5 copy a condensed continuation; nobody asked to copy a code block |
| Audit what the agent changed | 0 | none; backlog "Semantic filters" is flagged "validate demand" |

Nobody asked for any of these:
- syntax highlighting
- diff coloring
- a layout change
- any styling

Every reading complaint was about content that was missing or empty, not about its look. The
6.4 tool view and 55aec3c4 answered those complaints. Reddit and X replies in
`Marketing/STATUS.md` do not mention how the transcript looks.

Inference: AS users come to find a session and resume it. Reading matters, but users want it
to be complete and fast, not pretty. The case for polish rests on two things, not on user
requests:
1. Competitor parity: both history viewers and both agent apps color diffs and code.
2. Owner judgment of quality.

A small user base that does not file taste issues is weak evidence of no demand.

## 3. What to borrow, ranked by fit to a history browser

This is a proposal for the owner to cut. It is not a spec.

1. **Fold each turn's work into one line.** Show "Worked for 2m 57s · 14 tools · 3 files
   +42 −1", and open the tool rows on click (Codex desktop). This serves the main reading task:
   a scan of a past session shows prompts and answers first. AgentsView's focused mode and
   AS's role filters do the same job by other means. Check whether a fold makes the filters
   redundant.
2. **Diff coloring.** Use a unified diff with a gutter of old and new line numbers. Tint added
   and removed lines at about 10% green and red, and use the stronger GitHub light values for
   the gutter. Cut at 200 lines with "N lines total" and an Open action. Leave out word-level
   emphasis in v1. AS draws its own text, so this is cheap, and every peer has it.
3. **Exit-code status on shell rows.** A non-zero exit marks the row failed with a red marker,
   even when the tool record says "completed" (OpenCode, Codex TUI).
4. **Fold long user messages.** Fold past 12 lines and show 8 with "Show more". Pasted logs
   are common in history.
5. **Syntax highlighting in fenced code and Read results.** Use a native highlighter. Skip
   it above about 50,000 characters. Pick colors that follow light and dark mode. This is the
   most work and has the least direct value for a reader. Do it last.
6. **Small items:**
   - Find hits open collapsed rows without changing their saved state. Check AS first; it
     may already do this.
   - A copy button beside each code block, shown on hover.
   - Show the model in the turn footer only when it differs from the session's model.

Do not borrow:
- chat bubbles in heavy colors (AS keeps the flat HIG style; see memory
  `feedback_ui_native_hig_over_borrowed`)
- split diff view
- per-line diff comments
- Mermaid rendering
- sticky group headers (AS rows are one level deep)

## 4. Open questions for the owner

1. Does polish go ahead without user demand, on parity and quality grounds alone?
2. Should item 1 (the turn fold) come first, ahead of color? It changes the layout most, and
   it is the one item tied to the main reading task.
3. Should the Claude desktop UI and the expanded diffs in Codex and OpenCode be captured with
   the owner at the keyboard (full-screen control), or is the source research enough?
