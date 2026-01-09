# Unified Transcript Color System (PRD)

## Summary
Create a single, consistent transcript color system across the app so the Color transcript cards and the transcript toolbar legend communicate the same semantics: who is speaking, what is a tool call, and what is tool output (success vs error). Agent narrative blocks should use a light brand tint plus a brand strip (chat-like), without confusing green-branded agents (for example Droid) with successful tool output.

## Problem
The app currently has multiple “sources of truth” for transcript colors:
- Toolbar legend dots use one mapping (role palette).
- Color transcript cards use another mapping (card palette).
- Other transcript renderers (Plain/JSON/Analytics) use their own mappings.

This creates visible mismatches such as:
- Agent legend color not matching agent blocks in the transcript.
- Tool output in Color view reading like a different semantic category.
- Green being overloaded (agent in some places, tool success in others).

## Goals
1. Single source of truth for transcript semantics colors.
2. Color view agent narrative blocks are chat-like: brand strip + subtle brand tint.
3. Tool semantics remain semantic and unambiguous:
   - Tool call is distinct from tool output.
   - Tool output success is visually distinct from tool output error.
4. Toolbar legend and transcript visuals match.
5. Monochrome mode remains readable and distinct.

## Non-goals
- No changes to Find/search highlighting behavior in this scope.
- No redesign of session list colors.

## Definitions
### Semantic Categories
- User: human-authored prompt
- Agent: assistant narrative text
- Tool call: tool invocation payload
- Tool output success: tool result output with “success” classification
- Tool output error: tool result output with “error” classification
- Error: explicit error blocks (may be tool result failure or parsing errors)

### Agent Brand Colors
Stable brand colors derived from `SessionSource` (Codex/Claude/Gemini/OpenCode/Copilot/Droid). Brand colors are stable across sessions to preserve recognition.

## Design Decisions
### D1: Brand Mode (default)
Use stable per-agent brand colors in transcript UI:
- User: semantic blue
- Tool call: semantic purple
- Tool output success: semantic green
- Tool output error: semantic red
- Agent: brand color derived from `SessionSource` (brand strip + light brand tint)

### D2: Green-Brand Caveat (Droid)
Do not remap agent hues globally. Instead disambiguate “agent narrative” from “tool success” by styling:
- Tool success uses a solid 4px capsule strip.
- Agent narrative uses a distinct “agent strip style” even when the brand hue is green (for example a two-tone strip or inset highlight).

This preserves brand identity while keeping “green tool output” unambiguous.

### D3: Optional Distinct Mode (future)
When evaluating many agents simultaneously, optionally assign agent colors from a palette that avoids reserved semantic hues (user blue, tool purple, success green, error red), while showing an explicit mapping in the legend. This is not required for the initial implementation.

## UX Requirements
### R1: Color transcript cards
In Color view:
- Every semantic category has a consistent, recognizable card treatment.
- Agent cards use brand strip + subtle brand tint (chat-like).

### R2: Accent strip geometry
- Strip width: 4px
- Strip has rounded caps (capsule)
- Tool semantics use solid strips
- Agent semantics use a visually distinct strip style (not solid) to avoid green confusion

### R3: Toolbar legend
Toolbar legend dots must match the transcript semantics:
- User dot uses user semantic color
- Agent dot uses agent brand color
- Tools dot uses tool call semantic color
- Errors dot uses error semantic color

### R4: Monochrome mode
Monochrome mode must preserve semantic distinctions via grayscale and/or alpha.

## Implementation Notes
- Introduce a single palette module (e.g. `TranscriptColorSystem`) providing both `NSColor` and SwiftUI `Color`.
- Update:
  - Color view card renderer to use `TranscriptColorSystem` and per-session brand color for agent narrative.
  - Transcript toolbar legend to use `TranscriptColorSystem`.

## Acceptance Criteria
- Toolbar dots and transcript cards match for user/agent/tools/errors.
- Tool output success is visually distinct from agent narrative, even for green-branded agents.
- Tool output error is clearly distinct from tool output success.
- Light and dark mode both look coherent and readable.
- Monochrome mode remains usable.
