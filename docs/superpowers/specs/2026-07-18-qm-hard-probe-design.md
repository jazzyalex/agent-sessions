# QM Hard-Probe: Toolbar Trigger + Per-Provider Feedback — Design

Date: 2026-07-18
Status: approved in chat (owner) · Codex design review applied
Supersedes: the QM double-click probe gesture and the uncommitted overlay-capsule
prototype (`HUDProbeFeedback` global caption + `HUDProbeFeedbackTag` in
`AgentCockpitHUDView.swift`).

## Problem

The QM's manual hard probe is wired to an undiscoverable double-click on the
meters, and both call sites discard the completion — "probing" and "failed"
both render as nothing. Separately, the probe entry points themselves cannot
support reliable feedback: `CodexUsageModel.hardProbeNow` and
`ClaudeUsageModel.hardProbeNowDiagnostics` silently return without ever calling
their completion when `isUpdating` is already true, and Codex's
`hardProbeNowDiagnostics` doesn't maintain `isUpdating` at all — so a caller
that optimistically renders "probing…" can hang in that state forever, and two
surfaces can race the same probe with the loser mis-reporting "Probe already
running" as a real failure.

## Design

### 1. Trigger: QM toolbar button with per-click provider menu

- A probe button joins the QM's hover-revealed toolbar (chrome layer).
- Click opens a compact menu: **Probe Claude / Probe Codex / Probe Both**.
  - Only enabled providers (agent + usage tracking on) appear.
  - A provider's item is disabled while that provider's probe state is
    `.probing`, and when the provider's authoritative auth state makes a probe
    impossible (signed out / CLI missing) — with an explanatory tooltip.
  - **Probe Both is an atomic eligibility decision:** disabled if *either*
    provider is busy or ineligible. It never silently degrades to probing only
    the free provider.
- Both QM double-click sites are **removed**. The main-window strip's Codex
  double-click, the menu-bar dropdown's "Hard Refresh" items, and the
  Preferences "Usage Probes" buttons all remain as surfaces, but every one of
  them routes through the coordinator (§2) — one acceptance gate, one published
  probe state. Each surface keeps its existing presentation (dropdown failure
  alerts, Preferences diagnostics dialogs); the coordinator's typed result
  callback carries the provider diagnostics they need. An `.alreadyRunning`
  rejection is a silent no-op everywhere (matching the old `isUpdating`
  guards), never an alert.

### 2. ProbeCoordinator: one authoritative per-provider gate

A small app-level `@MainActor` coordinator (outlives the QM window — closing
and reopening the QM mid-probe must show the still-running state) owns all
hard-probe requests from every surface (QM toolbar, menu-bar dropdown,
Preferences, main-window strip).

- `request(provider) -> Acceptance` returns **synchronously** either
  `.started` or `.alreadyRunning`. Callers never infer acceptance from a
  preflight `isUpdating` read.
- Every accepted request **always** completes with a typed result:
  `.ok`, `.failed`, or `.suppressed(reason)` — the auth-guard short-circuits
  (exit 126 / unavailableMessage) map to `.suppressed`, never `.failed`; a
  guard doing its job is not a failed probe.
- The coordinator wraps the existing model entry points; as part of this work
  the entry points are fixed so acceptance is knowable: Codex's
  `hardProbeNowDiagnostics` sets/clears `isUpdating` like its non-diagnostics
  sibling, and both models' busy-path early returns are replaced by an
  explicit `.alreadyRunning` completion (or a synchronous rejection the
  coordinator can surface).

### 3. Per-provider probe state, expiry as data

Coordinator publishes `probeState[provider]`:

```
enum ProbeRowState {
    case none
    case probing(generation: UInt64)
    case failed(until: Date, generation: UInt64)
}
```

- Each provider's lifecycle is independent: with Probe Both, a fast Claude
  failure starts its ~8 s failure window immediately, regardless of the slower
  Codex probe.
- Expiry is data (`until: Date`), rendered against the shared QM clock tick —
  not a sleeping UI task. The `generation` stamp prevents a stale completion
  or expiry from clearing a newer probe's feedback.

### 4. Feedback: in-row status text

- While `.probing`: the provider's meter row swaps its numbers for `probing…`.
- On `.failed`: the row shows `probe failed` until `until`, then reverts.
- On `.ok`: fresh numbers replacing the row IS the feedback.
- On `.suppressed`: no fake failure — the row falls back to its normal
  presentation (the auth cell / idle cell already explains the underlying
  cause; menu-item disabling prevents most suppressed runs up front).
- Row precedence: `needsAction (alarming auth) > probe state > idle /
  reconnecting / live numbers`. A running probe never hides an actionable
  signed-out state.
- Text swaps inside the existing fixed-height row — the QM window height never
  changes from transient chrome (settled constraint).

### 5. Copy changes

- Idle recovery-ladder tooltip (`UsageAuthStatus.make`, `.idle`, Claude): last
  rung changes from "double-click the meter" to "use the probe button in the
  Quick Meter toolbar", keeping the may-consume-tokens caveat.

### 6. Prototype rework

- Delete the global overlay capsule (`HUDProbeFeedbackTag`, overlay wiring,
  global `isRunning`/`message`).
- The pure outcome→caption mapping and its tests are superseded by
  per-provider state-transition tests (§7).

## Testing

- Pure/unit: coordinator acceptance (`.started` vs `.alreadyRunning`,
  per-provider independence, Probe Both atomicity), result mapping
  (`.suppressed` vs `.failed`), generation guard (stale completion cannot
  clear newer state), expiry-as-data behavior.
- Entry-point regression: busy-path now always completes (no hang).
- View wiring: build-covered; owner visual QA at feature-complete (batched,
  per repo practice).

## Out of scope

- Auto-probe scheduling / frequency (probe stays manual; token cost).
- Main-window strip UX changes beyond routing through the coordinator.
- The four already-shipped fixes reviewed alongside this design (provisional
  path cap, presentationState reorder, via-claude.ai tag, ladder copy) —
  unchanged except the ladder's last rung (§5).
