Here’s a repo-aware spec you can drop into docs/session-viewer-terminal-raw.md (or similar). It’s written against your actual code: UnifiedTranscriptView, PlainTextScrollView, SessionTranscriptBuilder, TranscriptRenderMode, etc.

⸻

Session Viewer v2

Transcript | Terminal | Raw JSON

1. Current State (Codex / Claude Sessions)

1.1 Main view
	•	TranscriptPlainView is now a thin wrapper over:

UnifiedTranscriptView<SessionIndexer>


	•	UnifiedTranscriptView:
	•	Owns state like renderModeRaw (string backing TranscriptRenderMode), transcript, commandRanges, userRanges, etc.
	•	Uses PlainTextScrollView (NSTextView wrapped in NSScrollView) to show text.
	•	Supports “Terminal mode” via TranscriptRenderMode.terminal, but:
	•	For many sessions it falls back to normal transcript text (buildPlainTerminalTranscript(..., mode: .normal)).
	•	Colorization relies on commandRanges/userRanges only when a session has .tool_call events.
	•	Result: Terminal often looks almost identical to Transcript.
	•	PlainTextScrollView:
	•	Configures a single NSTextView:
	•	Monospaced system font.
	•	Non-contiguous layout.
	•	Scrollable, no horizontal scrolling.
	•	On update:
	•	Sets tv.string = text.
	•	Calls applySyntaxColors(_:) to color ranges.
	•	Calls applyFindHighlights for in-view search.
	•	applySyntaxColors currently:
	•	Uses commandRanges, userRanges, assistantRanges, outputRanges, errorRanges to apply orange / blue / gray / teal / red, etc.

1.2 Transcript building
	•	SessionTranscriptBuilder provides several public entrypoints:
	•	buildPlainTerminalTranscript(session:filters:mode:)
	•	buildTerminalPlainWithRanges(session:filters)
(returns (String, [NSRange], [NSRange]) for commands & user lines)
	•	buildANSI(...) (not currently used in the UI).
	•	Older / richer attributed builders (buildAttributed).
	•	Transcript logic:
	•	Events are converted to LogicalBlock instances and merged.
	•	render(block:options:) then formats text.
	•	When options.renderMode == .terminal:
	•	Assistant lines get [assistant] marker.
	•	Tool calls are rendered via renderTerminalToolCall(...).
	•	Tool output and errors get [out] / [error] markers instead of ⟪out⟫ / ! error.
	•	renderTerminalToolCall:
	•	Special-cases toolName == "shell":
	•	Tries to decode command: [...] or script from JSON.
	•	Falls back to toolPrefix + compactJSONOneLine(input) otherwise.

1.3 Raw JSON
	•	WholeSessionRawPrettySheet at the bottom of TranscriptPlainView:
	•	Shows a modal sheet with a segmented control:
	•	“Pretty” = PrettyJSON.prettyPrinted([... events.rawJSON ...])
	•	“Raw JSON” = raw events.map { $0.rawJSON }.joined(separator:"\n")
	•	Uses ScrollView + Text with monospaced font.

This already does 80% of what “Raw mode” needs—just not integrated as a first-class view mode.

⸻

2. Problems & Goals

2.1 Problems
	1.	Terminal mode often looks like Transcript
	•	For sessions with no .tool_call events or when colorization is disabled, UnifiedTranscriptView calls buildPlainTerminalTranscript(..., mode: .normal).
	•	That text is visually nearly identical to the normal transcript (no [assistant], no explicit CLI-style hints).
	•	Users can’t tell why they should ever switch.
	2.	No integrated Raw JSON mode
	•	Raw JSON is only available via a sheet (WholeSessionRawPrettySheet).
	•	It’s not discoverable and doesn’t feel like “one of the core three views.”
	3.	Terminal “vibe” is incomplete
	•	We already have:
	•	TranscriptRenderMode.terminal
	•	renderTerminalToolCall(...)
	•	ANSI utilities, command ranges, etc.
	•	But they are not consistently used to build the primary Terminal experience. Right now it’s essentially:
“Transcript + some colored ranges if you’re lucky.”

2.2 Goals
	1.	Three clearly distinct modes in the Session Viewer:
	•	Transcript – human-oriented chat, minimal noise.
	•	Terminal – what you’d expect to see in iTerm/zsh when running Codex / Claude Code.
	•	Raw JSON – debugging view over the actual .jsonl/events.
	2.	Terminal as the default “pro” view
	•	Single scrollable surface; no cards, no expanders, no “rows.”
	•	Colors and marker prefixes that are obviously terminal-like.
	•	Works well even for sessions with no executed commands.
	3.	Minimal structural changes
	•	Reuse UnifiedTranscriptView and PlainTextScrollView.
	•	Keep SessionTranscriptBuilder as the central source of truth.
	•	Avoid introducing a web view or completely new text component.

⸻

3. Mode Definitions

3.1 Transcript Mode (status quo, clarified)

Audience: “I want to skim what the agent and I said.”

Source: SessionTranscriptBuilder.buildPlainTerminalTranscript(session:filters:mode:.normal)

Characteristics:
	•	Grouped and formatted as conversation:
	•	User prefixes (> ).
	•	Normal “out” markers (⟪out⟫), ! error etc.
	•	No [assistant], [out], [error] labels.
	•	Colorization (via ranges) can stay modest:
	•	User input lines: subtle blue.
	•	Tool output: teal.
	•	Errors: red.
	•	Timestamps optional (controlled by filters/options).

Implementation notes:
	•	Keep using the existing pipeline you already have for Transcript mode.
	•	Ensure when renderModeRaw == .normal:
	•	SessionTranscriptBuilder.buildPlainTerminalTranscript(..., mode: .normal) is always used.
	•	buildTerminalPlainWithRanges is only used when mode is .terminal.

⸻

3.2 Terminal Mode (primary “CLI reconstruction”)

Audience: “Show me what Codex / Claude actually printed, as if I had saved my terminal output.”

Source: SessionTranscriptBuilder.buildTerminalPlainWithRanges(session:filters) + .terminal formatting.

3.2.1 Text pipeline
	1.	In UnifiedTranscriptView when renderMode == .terminal:
	•	Always use Terminal render mode text:
	•	If colorization + commands available:

let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
transcript = built.0
commandRanges = built.1
userRanges = built.2


	•	If there are no commands or colorization is off:
	•	Still call:

transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
    session: session,
    filters: filters,
    mode: .terminal
)
commandRanges = []
userRanges = []


	•	This guarantees the textual form is terminal-oriented even when there are no ranges.

	2.	Ensure buildPlainTerminalTranscript uses:

let opts = options(from: filters, mode: .terminal)

whenever Terminal mode is requested.

	3.	render(block:options:) with .terminal already:
	•	Adds [assistant] marker.
	•	Uses [out] and [error].
	•	Uses renderTerminalToolCall for .toolCall blocks.
That’s the core of the desired CLI-ish look; we just need to wire it consistently.

3.2.2 Visual style (in PlainTextScrollView.applySyntaxColors)
Use ranges to make the CLI structure immediately obvious:
	•	User ranges (userRanges)
	•	Foreground: light blue.
	•	These lines start with > . Good mental mapping to “you” in a CLI.
	•	Command ranges (commandRanges)
	•	Foreground: system orange (you already apply this).
	•	These are typically rendered from renderTerminalToolCall(shell, input):
	•	First line: bash ... (header).
	•	Next line: actual command (from script or command[2...]).
	•	Tool output ranges (outputRanges)
	•	Foreground: teal/cyan (you already have logic).
	•	Represents [out] lines.
	•	Error ranges (errorRanges)
	•	Foreground: red.
	•	Represents [error] lines, including failed commands.
	•	Assistant / meta ranges (assistantRanges / meta)
	•	Foreground: softer gray.
	•	These lines are prefixed with [assistant] when renderMode == .terminal.

Additional tweaks:
	•	When renderMode == .terminal, consider a slightly darker textView.backgroundColor:
	•	To get closer to a real terminal, but still match app theme (respect AppAppearance + macOS color scheme).
	•	Keep the view text only:
	•	No inline icons or overlays.
	•	The inline “No commands recorded; Terminal matches Transcript” banner you already show is fine, but keep it above the text area (as you already do), not inside it.

3.2.3 Mapping events → terminal “feel”
The goal is to loosely mimic Codex / Claude output without being pixel-perfect:
	•	User instructions:

> Fix the Sparkle DMG version mismatch and regenerate the appcast.


	•	Assistant planning/status (with marker):

[assistant] Plan:
  1. Update MARKETING_VERSION.
  2. Fix appcast.xml.
  3. Rebuild DMG and verify Sparkle.


	•	Shell commands:
From toolName == "shell" with command: ["bash", "-lc", "<cmd>"]:

bash -lc
./scripts/build_dmg.sh --profile release

or, for generic commands:

shell ["pytest", "-q"]


	•	Tool output:

[out] ✔ DMG build completed: dist/AgentSessions-2.6.1.dmg
[out] ✖ error: version mismatch in appcast.xml (found 2.5.4, expected 2.6.1)


	•	Errors:

[error] Command failed with exit code 1
[error] stderr: appcast.xml: expected 2.6.1, found 2.5.4


	•	Meta:

· meta checkpoint "after-dmg-fix"



Your existing builder already produces most of these; the spec here is mainly about:
	•	Ensuring .terminal mode is always used in Terminal view.
	•	Strengthening color mappings so these roles are visually distinct.

3.2.4 Sessions without commands
Problem today: in sessions without .tool_call, Terminal view falls back to pretty much normal Transcript.

Spec:
	•	For hasCommands == false:
	•	Still format via .terminal mode (so [assistant] markers appear).
	•	Keep the inline banner you already show:
“No commands recorded; Terminal matches Transcript”
but after these changes, “matches Transcript” really means “content is similar, but with terminal-style markers and colors.”

⸻

3.3 Raw JSON Mode

Audience: “I’m debugging a parser / indexer issue, I want the real events.”

Instead of a separate sheet, we promote this to one of the main modes.

3.3.1 UX
	•	Top of UnifiedTranscriptView gets a 3-way segmented control or similar:

Transcript | Terminal | Raw


	•	“Raw” instantly switches the main scrollable area to Raw view.
	•	Cmd+Option+J (example) can be bound as a shortcut to toggle Raw mode if desired.

3.3.2 Content
	•	Use the logic from WholeSessionRawPrettySheet:
	•	Pretty JSON (default sub-mode for Raw view):

[
  { "type": "thread.started", "thread_id": "...", ... },
  { "type": "turn.started", "timestamp": "...", ... },
  ...
]

	•	Use PrettyJSON.prettyPrinted("[" + events.map(\.rawJSON).joined(separator: ",") + "]").

	•	Optional: simple toggle inside the Raw view itself for “Pretty | Raw JSON” using the same segmented control you already have in the sheet.

	•	Use the same PlainTextScrollView or a simpler SwiftUI ScrollView + Text:
	•	Monospaced system font.
	•	Syntax coloring for JSON:
	•	Keys (quoted) in one color.
	•	Strings one color.
	•	Numbers / booleans another.
	•	Braces/brackets in neutral.
You can either:
	•	Reuse PlainTextScrollView and add a dedicated “JSON mode” (no command/user ranges, but JSON token highlighting), or
	•	Keep it simple and just use ScrollView { Text(pretty).font(.system(.body, design: .monospaced)) } for v1.

⸻

4. Wiring Modes in UnifiedTranscriptView

4.1 Mode enum

You already have:

enum TranscriptRenderMode: String, CaseIterable, Identifiable, Codable {
    case normal
    case terminal
}

For the view, introduce a separate enum to include Raw:

enum SessionViewMode: String, CaseIterable, Identifiable, Codable {
    case transcript    // uses renderMode = .normal
    case terminal      // uses renderMode = .terminal
    case raw           // bypasses transcript builder, shows JSON
    var id: String { rawValue }
}

State in UnifiedTranscriptView:

@AppStorage("sessionViewMode") private var viewModeRaw: String = SessionViewMode.transcript.rawValue
private var viewMode: SessionViewMode {
    get { SessionViewMode(rawValue: viewModeRaw) ?? .transcript }
    set { viewModeRaw = newValue.rawValue }
}

Mapping:
	•	When viewMode == .transcript:
	•	renderMode for builder = .normal.
	•	When viewMode == .terminal:
	•	renderMode for builder = .terminal.
	•	Use buildTerminalPlainWithRanges.
	•	When viewMode == .raw:
	•	Skip transcript builder; use Raw JSON view.

4.2 Top-level switch in body

Conceptually:

switch viewMode {
case .transcript:
    transcriptPlainView(body configured with .normal)
case .terminal:
    transcriptPlainView(body configured with .terminal)
case .raw:
    rawJSONView(session: session)
}

The important part is that Transcript and Terminal still share PlainTextScrollView and find/highlight machinery; Raw is a separate branch.

⸻

5. Implementation Steps (code-oriented checklist)
	1.	Introduce SessionViewMode and viewModeRaw in UnifiedTranscriptView.
	2.	Replace existing renderModeRaw usage:
	•	Use SessionViewMode.transcript/.terminal instead of TranscriptRenderMode directly.
	•	Maintain a small helper to derive TranscriptRenderMode from SessionViewMode when calling builders.
	3.	Rewire transcript building for Terminal:
	•	In the async build task:
	•	For .terminal view mode:
	•	Prefer buildTerminalPlainWithRanges if session.events.contains(.tool_call) and colorization is on.
	•	Otherwise buildPlainTerminalTranscript(..., mode: .terminal).
	•	For .transcript view mode:
	•	Always buildPlainTerminalTranscript(..., mode: .normal).
	•	Ensure lastBuildKey incorporates both viewMode and filters so caches don’t leak across modes.
	4.	Update PlainTextScrollView.applySyntaxColors to:
	•	Recognize when view is Terminal vs Transcript (via a flag or by just inspecting range arrays).
	•	Strengthen colors for command/user/output/error ranges in Terminal.
	•	Optionally reduce assistant/meta emphasis in Terminal.
	5.	Integrate Raw mode:
	•	Extract the logic from WholeSessionRawPrettySheet into a reusable helper:

func sessionPrettyJSON(_ s: Session) -> String
func sessionRawJSON(_ s: Session) -> String


	•	Add a RawJSONView(session:) that uses those helpers.
	•	Use this view when viewMode == .raw instead of the transcript/terminal text.

	6.	Simplify or repurpose WholeSessionRawPrettySheet:
	•	Either:
	•	Delete it and map old entrypoint to switching to Raw mode, or
	•	Keep it but have it embed RawJSONView so behavior is consistent.
	7.	QA with real sessions:
	•	Pick:
	•	A Codex session with lots of shell commands.
	•	A Claude Code session heavy on plan text + shell.
	•	A chat-only session with no commands.
	•	For each, compare:
	•	Real terminal output vs Terminal mode string.
	•	Transcript vs Terminal vs Raw modes.
	•	Iterate colors and markers until the CLI “feel” is obvious at a glance.

⸻

If you want, next step I can turn this doc into a Codex-ready prompt that walks a coding agent through the exact edits file-by-file (TranscriptPlainView.swift, SessionTranscriptBuilder.swift, UnifiedTranscriptView, etc.), including what to rename, what to remove, and how to keep behavior backward-compatible.
