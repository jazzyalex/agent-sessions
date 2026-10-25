Exported 2026-10-24 from a Repo MCP product-market-fit pass.

- Execution surface: ChatGPT web
- Coordinator: Claude Code (claude-opus-5-5)
- Verified profile: architecture / Pro
- Repository evidence: Repo MCP, read-only `inspect` workspace; HEAD `a3e3fb357d09ce5f6bf614062ab654ecffecc7fb`; `phase_only` assurance; planning docs read as live untracked files
- Run ID: `a0a9face-223f-46ef-8e37-8f8e9099dd15`
- Conversation: https://chatgpt.com/c/6add7e24-1cf0-83e8-b891-88df76c145f8 (archived after completion)
- Task: `agent-sessions-crash-coalition-review-20261022` (reused; rebound to current HEAD; not finished by this pass)
- Output source: `mcp-report`
- Original output SHA-256: `3aae225623a4d7ba79ad1164af9aabe8604dfb2f5cc96c58c88a71ae76ac03c4`
- Prompt SHA-256: `5f31d749edc01a1be7d6f4c49353f50487e0825e8e655fad8dc4e571dccc51c8`

The readable export removes only non-Markdown UI citation markers. Questions asked: Q1, do we need a CLI and/or TUI at all; Q2, what the macOS part of PR #77 takes without its contributor. No edits, builds, runtime tests, private-history reads or external messages were performed. Effort figures are the reviewer's planning estimates, not measurements.

---

# Agent Sessions: CLI and TUI product decision

## 1. Answer to Q1 in three sentences

Agent Sessions does not yet have enough evidence to justify the planned general-purpose CLI, and I would not adopt or build the TUI now. The strongest demonstrated need is narrower: an existing user wants a coding agent to save the current Codex conversation as a readable transcript, which should first be tested against the released Codex support in `claude-code-log`. If that leaves a repeatable gap, a capped macOS export experiment is justified; a maintained retrieval CLI should wait for repeated use and a concrete advantage over existing tools.

### Reasoning and evidence standard

**The strongest case is for extending an existing workflow, not establishing another general session-search product.** Agent Sessions already promises local discovery, search, inspection, and resumption across coding agents. Its current GUI can export Markdown. A command that lets an installed coding agent use that existing capability could be valuable, but the proposed search/index/read platform is a much larger commitment. [`README.md:5–9,29–35`; `docs/index.html:510–537,574–590`; `AgentSessions/Views/TranscriptPlainView.swift:34–119,2775–2802`.]

**Review scope.** Repository identity matched at opening and final recheck: `/Users/alexm/Repository/Codex-History`, branch `main`, HEAD `a3e3fb357d09ce5f6bf614062ab654ecffecc7fb`. No mismatch, edits, or access to private session histories. I read the repository instructions, newest handover, bounded planning/product evidence, and relevant current and historical source. This is source and document analysis, not a runtime qualification or fresh merge simulation; Repo MCP reported `phase_only` assurance, and the planning documents are live untracked files.

References to current code below mean that HEAD unless identified as live planning documents. **P77** means [`4b546dcc…`](https://github.com/shurrman/agent-sessions/tree/4b546dccceaa5862d36453979100026ca37d7353), based on `ad06d49c…`; **C1** means companion [`4c51ca4d…`](https://github.com/shurrman/agent-sessions/tree/4c51ca4d8726f430a820dbb9b0ee18d41e88f772). External checks were made on **2026-10-24 Pacific / 2026-10-25 UTC**. Competitor capabilities below are verified in primary documentation/source, not runtime-tested. Recommendations, effort ranges, and proposed adoption thresholds are judgments, not measured outcomes.

Three observations determine the recommendation:

- **There is one explicit CLI requester, asking for export.** In [#80](https://github.com/jazzyalex/agent-sessions/issues/80), opened September 30, the October 2 clarification describes regularly archiving readable conversations and decisions, wants an agent to archive the current chat, and explicitly does not need list functions. They already use `claude-code-log` for Claude Code. This is a credible individual job, with self-reported recurrence; it is not evidence for cross-provider search, a TUI, or a particular weekly frequency. [Detailed clarification, 2026-10-02](https://github.com/jazzyalex/agent-sessions/issues/80#issuecomment-5962133506).
- **Existing product evidence supports human retrieval and readable export.** The survey analyzes 16 responses in different cohorts; only the ten manual-form responses support the “10/10 history, 10/10 search” counts. It does not establish CLI demand or usage frequency. Separately, [#29](https://github.com/jazzyalex/agent-sessions/issues/29), opened March 30, requested transcript export, and its requester confirmed the implemented GUI feature worked on April 7. [`docs/product-feedback/2026-09-14-google-form-survey-report.md:7–12,25–56,119–121`; [#29 confirmation](https://github.com/jazzyalex/agent-sessions/issues/29#issuecomment-4201456281).]
- **The supposed Codex-export gap has narrowed.** The released [`claude-code-log` 1.7.0 README](https://github.com/daaain/claude-code-log/blob/1.7.0/README.md), released October 5, documents beta single-session Codex support using `--provider codex --session-id`. Whether it handles the requester's exact current-chat workflow remains unknown. That is the first comparison to run, because the requester already uses the product.

The public issue searches found no additional explicit CLI requester and no Linux, MCP, or headless request in the searched terms. That is **absence of observed demand in a macOS application's issue tracker**, not proof that those markets do not exist. [#25](https://github.com/jazzyalex/agent-sessions/issues/25), March 18, concerns copying a resume command into the user's terminal workflow; it does not request terminal browsing.

Upstream continuity complaints also need separation. Claude Code [#15542](https://github.com/anthropics/claude-code/issues/15542) concerns access to Claude.ai conversations; [#27242](https://github.com/anthropics/claude-code/issues/27242) concerns access to earlier/branched history; [#11455](https://github.com/anthropics/claude-code/issues/11455) describes a curated handoff workflow. Their verified 98, 91, and 26 reactions concern adjacent problems, not demand for this CLI. Conversely, zero reactions on duplicate search requests [#30744](https://github.com/anthropics/claude-code/issues/30744) and [#72574](https://github.com/anthropics/claude-code/issues/72574) are weak negative evidence. Stars, the owner's growth target, and architecture approval receive no demand weight.

## 2. Segments and jobs

“Frequency unknown” means the evidence does not measure it; it does not mean the job never occurs.

| Candidate user | Job and frequency evidence | Current workaround | Reason to choose Agent Sessions | Confidence |
|---|---|---|---|---|
| **Existing GUI user** | Find earlier work, inspect it, resume, or preserve a transcript. Survey and #29 support these jobs; agent-invoked frequency is unknown. | Current GUI search/export; copy a resume command; provider-native history. | **Hypothesis:** invoke the same trusted parser/exporter from the coding agent, with consistent results and no second history system to configure. | High that GUI jobs exist; low–medium that a command materially improves enough users' workflow. |
| **Agent-first user without the GUI** | Retrieve a past decision or code discussion while another agent is working. Recurring use is plausible but unmeasured here. | AgentsView CLI/MCP, cass robot mode, episodic-memory, repository notes, direct file search. | Needs demonstrated better retrieval/fidelity or simpler operation. “Install a Mac app first” may be a disadvantage. | Low evidence for choosing Agent Sessions. |
| **Terminal/SSH user** | Browse/filter/read sessions without leaving the terminal or without a graphical display. No measured TUI frequency; #25 establishes terminal handoff friction only. | Native resume pickers, shell tools, cass, deja-vu, claude-code-log. | **Hypothesis:** superior keyboard workflow on histories already available to Agent Sessions. Remote histories and local Mac histories may be different corpora. | Low; no demonstrated unmet browsing job. |
| **Linux user** | Local multi-agent history browsing/search on Linux. PR #77 demonstrates contributor interest, not recurring end-user use. | Existing cross-platform tools and native agent commands. | Would need a tested advantage plus dependable Linux installation and updates. None is established. | Very low for this maintainer's expansion decision. |
| **The #80 requester** | Ask the coding agent to archive the current Codex conversation as readable Markdown/JSON/text, then optionally extract relevant sections. They say they do this often, without a numeric frequency. | GUI export for full chats; claude-code-log for Claude; manual selection/path copying. | Correct current-session selection and a readable saved artifact from one in-chat request, including when the GUI is not running. | High that this individual's problem is real; unknown that a new implementation is necessary or broadly wanted. |

Sources: survey and issues cited above; current native and competitor capabilities cited below. The switching reasons marked as hypotheses have not been demonstrated by adoption.

**The #80 job is “save this conversation,” not “search all previous conversations.”** A known-session exporter can serve it without a search index, ranking, cursor pagination, or terminal UI. A bounded read response is also not a substitute for an archive: a command can correctly truncate its response while still failing the user's preservation job. [#80 clarification; live `docs/plans/2026-10-23-macos-cli-shipping-plan.md:129–139`.]

## 3. Competitive position

The relevant question is whether Agent Sessions removes a recurring cost that these tools leave behind.

| Alternative | Verified relevant capability | Possible Agent Sessions advantage—and its limit |
|---|---|---|
| **AgentsView** | Released v0.46.1 documents JSON session search/list/messages, read-only MCP retrieval, revision-bound message continuation, and export. Local reads use a compatible background daemon. Its CLI session export returns raw source bytes; readable Markdown/HTML are available through HTTP endpoints. | An installed Agent Sessions helper could offer a direct, one-shot readable export with no additional service or archive setup. That is a specific workflow hypothesis. Cross-agent search, JSON, locality, and agent accessibility are already covered. |
| **cass** | Rust terminal browser, bounded robot-mode JSON, current-session lookup, and Markdown/JSON export. | Consistent output with an existing Agent Sessions GUI and proven handling of a particular current provider format might win. Terminal access, machine-readable retrieval, and export are not differentiators by themselves. |
| **Entire** | Captures reasoning alongside Git checkpoints; includes search and agent help. Experimental history import also exists. | Agent Sessions can remain useful across existing archives without adopting a checkpoint/hook workflow or organizing the job around Git. Entire may be preferable when linking decisions to code changes is the actual job. Do not claim it cannot ingest existing history. |
| **episodic-memory** | Imports/copies existing histories, offers semantic/text search and readable conversation access. Summaries are optional display assistance, not the only searchable artifact. | Direct export with no embedding/index setup may be simpler for a known conversation. For agents that need meaningful recall rather than a transcript, its retrieval workflow may be the stronger product. |
| **claude-code-log** | Human-readable export and terminal browsing; released 1.7.0 includes beta single-session Codex support. It is already the #80 requester's workaround for Claude. | Agent Sessions would need to demonstrate better current-chat identification, fidelity, compressed-history support, or integration. This is the hardest switching case to justify with convenience alone. |

Primary references, checked October 24/25: [AgentsView v0.46.1 session API](https://github.com/kenn-io/agentsview/blob/v0.46.1/docs/session-api.md), [MCP documentation](https://github.com/kenn-io/agentsview/blob/v0.46.1/docs/mcp.md); [cass README](https://github.com/Dicklesworthstone/coding_agent_session_search/blob/main/README.md); [Entire README](https://github.com/entireio/cli/blob/main/README.md); [episodic-memory README](https://github.com/obra/episodic-memory/blob/main/README.md); [claude-code-log 1.7.0 README](https://github.com/daaain/claude-code-log/blob/1.7.0/README.md).

SpecStory's Markdown-saving workflow, deja-vu's CLI/TUI/MCP, and claude-mem's memory workflow further crowd the surrounding space. Their popularity is not evidence that users want another implementation, but their existence raises the burden of proving a switching reason. [Primary repositories: [SpecStory](https://github.com/specstoryai/getspecstory), [deja-vu current README](https://github.com/vshulcz/deja-vu/blob/main/README.md), [claude-mem](https://github.com/thedotmack/claude-mem); checked October 24/25.] genui{"citation":{"refs":["turn22view0","turn22view2"]}}

Native tools cover some simpler jobs. Claude Code has a searchable session picker and readable-text export; Codex has resume; OpenCode documents JSON session listing/export; Cursor exposes `agent ls`. These do not prove that cross-provider recall is solved, but they reduce the value of another basic list/resume surface. [Claude Code session documentation](https://code.claude.com/docs/en/sessions); [Codex source](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/cli/src/main.rs); [OpenCode CLI](https://opencode.ai/docs/cli/); [Cursor CLI reference](https://cursor.com/docs/cli/reference/parameters); checked October 24/25. genui{"citation":{"refs":["turn20view6","turn22view3","turn22view4"]}}

**My competitive inference:** the defensible opening is a small convenience feature for people who already trust and install Agent Sessions. There is currently no demonstrated advantage that warrants entering the broader agent-memory or terminal-browser market. The June/July AgentsView memo remains useful history, but current released documentation must govern this decision. [`docs/competitive-agentsview.md:1–10`.]


## 4. CLI versus TUI

### CLI: distinguish export from retrieval

**A current-session exporter is a plausible feature of the existing product.** It has a concrete input, artifact, and beneficiary. It can be useful even to one person if its cost stays small and the owner consciously accepts that tradeoff. That is a different justification from claiming product-market fit.

**A general retrieval CLI is an unvalidated product extension.** It must help an agent select the right previous conversation, inspect enough context, distinguish stale or partial results, and cite the source accurately. Counting commands or matching competitors' APIs does not establish that the agent completes the user's task better. The planned `sources/index/list/search/read/resume-plan` surface addresses this larger job; it omits a full transcript-export command. [Live `docs/plans/2026-10-23-macos-cli-shipping-plan.md:129–139`.]

Agent discoverability is also part of the feature. A binary on disk does not teach an agent when to use it. A small skill with explicit invocation and output handling is a reasonable experiment; adding MCP is not necessary to test shell invocation. Native session identifiers help, but do not solve resolution automatically: Codex supplies `CODEX_THREAD_ID` when a thread ID is available, while current Agent Sessions can use a path hash for `Session.id`. [`AgentSessions/Services/SessionIndexer.swift:2461–2478`; [Codex exec environment, pinned source](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/core/src/exec_env.rs), lines 29–36.]

### TUI: do not commit now

**The TUI has no independently demonstrated job that warrants this owner's support commitment.** It does not help an agent consume JSON or save an archive; it serves a human choosing to browse in a terminal. That audience may exist, but the current evidence supplies neither repeat usage nor a reason to switch from existing terminal tools.

PR #77 is still a draft proposal, with no submitted reviews and no contributor response to the September 29 maintenance question. The contributor's September 20 console release has seven assets with one download each, including the checksum file. That is not seven users, and unknown exposure makes it a poor market rejection test. The correct conclusion is **no demonstrated adoption or maintenance commitment**, not “nobody wants it.” [PR [#77](https://github.com/jazzyalex/agent-sessions/pull/77), [owner's question](https://github.com/jazzyalex/agent-sessions/pull/77#issuecomment-5899242742), [console release](https://github.com/shurrman/agent-sessions/releases/tag/console-v0.1.0); checked October 24/25.]

A TUI should return to consideration only with its own repeat-use evidence, a verified advantage over existing terminal browsers, and an explicit maintenance budget or maintainer. A sound CLI contract merely makes a future TUI possible.

## 5. Cost and opportunity cost

The extra cost is not just command parsing or drawing a terminal interface.

**Provider drift becomes a compatibility obligation across surfaces.** Sharing current readers can prevent duplicate parser implementations, but it does not remove separate promises about identity, exit status, completeness, freshness, structured output, and installation. A GUI may display a partially readable conversation usefully; an archive command must not silently certify it as complete.

Current code shows why this matters:

- Codex parsing supports canonical paths backed by compressed rollouts and tracks read failure internally, while the public full-parse wrapper returns the session. A CLI needs to preserve the strict outcome. [`AgentSessions/Services/SessionIndexer.swift:2336–2374,2445–2449,2490–2495`.]
- Claude parsing includes format-specific skips and malformed-line handling; OpenCode spans file layouts and SQLite generations, including migration fallback behavior. These are continuing product responsibilities, not a fixed extraction task. [`AgentSessions/Services/ClaudeSessionParser.swift:32–68,119–171`; `AgentSessions/Services/OpenCodeSessionParser.swift:75–130`; `AgentSessions/OpenCode/OpenCodeSqliteReader.swift:54–97,1399–1414`.]
- The app index is not a transcript archive. It stores sampled search text; its normal initializer creates directories, opens the database for writes, and runs schema setup. Current ingestion also constructs an image cache and uses GUI-oriented freshness policies. [`AgentSessions/Indexing/DB.swift:136–159,185–235,419–470`; `AgentSessions/Search/SearchIngestService.swift:203–240,262–287`.]

A separate CLI cache adds migrations, freshness/deletion semantics, concurrent readers/writers, and another support state. Reading the app cache directly avoids some duplication but introduces dependence on the GUI having indexed the right roots recently, its private schema, and the sampled corpus. **Neither option is a cheap substitute for proving the search job.** A known-session export avoids most of this decision.

Distribution is also work: the existing release builds/signs the app, and the deployment script generates an app-only Homebrew cask. A helper requires build/embed/sign/verify work, an executable path users and agents can discover, and install/upgrade qualification. [`tools/release/build_sign_notarize_release.sh:97–99,134–146`; `tools/release/deploy-agent-sessions.sh:838–897`.]

**Opportunity-cost judgment:** the broad CLI estimate below consumes roughly four to eight full working weeks before its support tail. Those are weeks unavailable for the established product's parser reliability, search usefulness, export quality, and reported workflow friction. The survey identifies concrete historical issues around discoverability, freshness, titles, filters, and terminal handoff, although its own caveats require checking which remain unresolved today. [Survey report: `62–102`.]

Do not assume two surfaces double maintenance mechanically. The cost depends on how much behavior is genuinely shared and how many public promises are made. For budgeting, I would reserve **0.5–1 focused day per week during the first quarter after a broad CLI launch**, then measure actual work. That is a capacity scenario, not observed demand or a forecast that format drift will fit neatly into that allowance.

## 6. Smallest experiment that would change the answer

**Recommendation: test the complete current-Codex archive job before writing another CLI.** The following thresholds are proposed decision rules, not industry benchmarks or evidence already collected. Everything can be recorded manually; no telemetry or outbound user contact is required.

### Step A: compare the existing workflow, within 1–2 focused days

Use synthetic fixtures and owner-chosen material, if the owner chooses to test real conversations. Compare the current GUI export with released `claude-code-log` Codex support; use cass as a second comparator if the first leaves a material gap.

Exercise approximately ten cases covering explicit and current-session selection, concurrent sessions in one directory, resumed sessions, a long conversation, Unicode, tools/errors, compressed storage, and a changing active history. Test invocation from the agent with the GUI closed—not just parsing a known file.

Record correct identity, readable preservation, manual interventions, elapsed workflow time, and any missing content. The initial acceptance bar should be:

- **Correct session in every case**, with ambiguity reported instead of selecting the newest file.
- **No silent omissions or truncation reported as a complete archive**, within an explicitly declared text-export scope.
- At least **9/10 workflows completed without manual path hunting**, once configured.
- A concrete convenience advantage: for example, at least **30% less median hands-on time** than GUI export, or removal of a repeatedly troublesome manual step.

If an existing tool meets the job adequately, **do not build a competing exporter for this rationale**. A documented invocation or contribution to that tool may be sufficient. If it fails, record the precise failure; a beta label is neither proof of adequacy nor disqualification.

### Step B: only for a demonstrated gap, cap an experiment at 2–4 days

Build an experimental **Codex-only, known-session Markdown exporter**, using current parsing and existing rendering where practical. Add a thin agent skill only to exercise invocation and identity handling. An explicitly supplied session is acceptable initially; “this chat” must be validated before claiming the #80 job is solved.

Keep the scope free of search indexing, pagination, TUI, statistics, MCP, extra output formats, and complete attachment archival. If identity resolution or packaging cannot fit the cap, stop and reassess rather than silently beginning the full plan.

### Step C: distinguish personal utility from a supported feature

For **14 days**, keep a local diary of genuine archive requests: why the artifact was needed, whether the session/output was correct, interventions, and the old workaround.

A reasonable **personal-utility pass** is five genuine saves across at least three days, readable and correctly identified output, and a concrete reduction in manual work. Record later reuse as supporting evidence, not a mandatory condition: preservation can be valuable before the archive is reopened. A quiet fortnight means “not enough observed need to invest now,” not “no market.”

If the owner later chooses to offer an experimental build publicly, a pragmatic **narrow-feature expansion gate** is three independent existing users, each completing at least three genuine uses across two weeks and explaining a specific advantage over their workaround. Record setup/support time as well as successes. This could justify cautiously supporting export; it would not establish broad product-market fit. No response without known exposure remains unknown.

**The broad CLI needs a different gate:** for example, three non-owner users each completing at least two genuine retrieval jobs per week for two weeks, with a concrete advantage over an existing retrieval tool on the same tasks. **The TUI needs a separate gate:** for example, three people repeatedly browsing histories in a terminal over two weeks, explaining a specific unmet need, together with sustainable ownership. These are thresholds for reconsideration, not proof of a market; successful export is not evidence for either expansion.


## 7. Answer to Q2: doing the macOS work without the contributor

**It is feasible to proceed independently, but the macOS work should be treated as a new, selectively informed implementation on current main.** PR #77 is a draft proposal touching 110 files, with +7,421/−2,608 lines, rather than an almost-ready feature whose remaining task is conflict resolution. The fork's last push was September 21; there is no observed agreement to maintain the TUI or Linux packaging. The owner-authored companion is also draft, with no comments or submitted reviews. These are current repository facts, not a judgment about the contributor's intentions. [PR [#77](https://github.com/jazzyalex/agent-sessions/pull/77); [companion #1](https://github.com/shurrman/agent-sessions/pull/1); [fork metadata](https://api.github.com/repos/shurrman/agent-sessions); checked October 24/25.]

The historical sources at the supplied refs were readable. I would not transplant the old parser extraction over today's readers or treat previously recorded conflict counts as a current merge result.

### Reuse map

“Reuse” below means a useful implementation or test asset after review/adaptation—not a claim that it already passes today's requirements.

| Source | Disposition | What survives; what must change |
|---|---|---|
| **P77 `Package.swift`** | **Port the pattern** | A headless executable build is useful. The manifest pulls a broad list of app sources into an executable target, with Linux-specific dependencies/settings. Reconstruct a deliberately bounded current dependency graph; it is not a ready-made standalone library. [`7–145`.] |
| **P77 `cli/as-core/Drivers.swift`** | **Port the pattern** | Keep the source-adapter and explicit-context idea. Rework discovery outcomes, supported-source selection, and native versus internal identity against current readers. Array-only discovery cannot adequately express all failure states. [`5–58`.] |
| **P77 `cli/as-core/Output.swift`** | **Reuse the separation; redo failure handling** | Machine output on stdout and diagnostics on stderr are useful. Replace serialization fallback to an empty object with explicit errors and stable result types. [`3–26`.] |
| **P77 `cli/as-core/Commands.swift`** | **Port command concepts; discard index/error plumbing** | Useful command sketches. Current production behavior needs strict exit/error contracts, current discovery and parsing, and the chosen cache boundary. The old mutable index setup and app-ingestion path do not implement the approved plan. [`167–243,313–364`.] |
| **P77 `cli/as-core/Stats.swift`** | **Discard from the macOS MVP** | Statistics, token/pricing interpretation, and telemetry readers add another changing domain without serving the demonstrated export job. [`11–12,27–47,79–113`.] |
| **P77 `scripts/as_core_contract.py`** | **Reuse the harness approach and selected fixtures** | Synthetic CLI contracts and golden comparisons are valuable. Existing checks omit important fields and do not establish current transcript fidelity or the new protocol. Update expectations and add current edge cases; do not count old tests as current qualification. [`2–7,31–83`.] |
| **P77 `tui/main.go` and `tui/core.go`** | **Discard from current scope; retain as reference** | There is UI scaffolding, but production adoption still needs paged/revision-aware previews, cancellation, bounded output, robust subprocess errors, and terminal text handling. The client buffers full output; preview caching is keyed by ID; some error handling is incomplete. [`core.go:185–220,248–260`; `main.go:214–244,347–358`.] |
| **C1 `cli/as-core/Commands.swift`** | **Reuse UTF-8 helper; port bounded-read concepts** | The Unicode-safe truncation helper and explicit truncation/trust ideas are useful. The read path fully reparses each page, lacks revision-bound continuation, compares against internal session identity, and begins with a literal file-existence check that does not cover today's canonical compressed-path behavior. [`169–248`.] |
| **C1 `docs/cli-history-retrieval.md`** | **Port the contract vocabulary** | Preserve explicit limits, trust boundaries, and honest sampling/pagination caveats. Rewrite around the actual chosen product: bounded agent reading and complete readable export require different promises. [`27–107`.] |
| **C1 `scripts/as_core_read_contract.py`** | **Reuse selected synthetic tests** | Keep Unicode, bounds, identity, and read-only regression cases. Add current provider fixtures, native-ID resolution, compressed and active history, and explicit incomplete/error outcomes. [`47–195`.] |

### Current-main work the PR does not remove

**Extraction remains real even with Linux excluded.** Current source descriptors import SwiftUI/AppKit and include appearance/telemetry factories; registry runtime construction is tied to main-actor app behavior. The headless boundary must be deliberate. This is a cost observation, not a request to redesign the already-reviewed architecture. [`AgentSessions/Model/SessionSourceDescriptor.swift:1–3,272–312,341–359`; `AgentSessions/Model/SessionSourceRegistry.swift:14–17,31–69`.]

**Export has a promising shortcut, with important limits.** `TranscriptMarkdownExporter.markdownContent` already renders conversation blocks and metadata. Its UI save flow, however, uses `NSSavePanel`, the app window, and a write whose error is suppressed with `try?`. Image handling can create asset files and file references. A CLI can reuse rendering, but needs explicit destination/error behavior, a declared attachment policy, and a reliable source snapshot. “Cheap text export” is plausible; “complete portable archive in one afternoon” is not established. [`AgentSessions/Views/TranscriptPlainView.swift:34–185,2775–2822`.]

**Mac delivery must be owned end to end.** The cask generator itself needs updating, not just one generated cask. Embedded helper signing, both processor architectures, macOS 14, upgrades through the existing app distribution, and executable discovery all need qualification. Homebrew supports a cask `binary` stanza; Apple's signing guidance calls for signing nested code before the enclosing app. Current scripts do not by themselves demonstrate that a new helper meets those conditions. [Release scripts cited in section 5; official Homebrew and Apple guidance, checked October 24/25.] genui{"citation":{"refs":["turn20view2","turn20view3"]}}

### Owner-alone effort

These are **planning estimates**, not measured estimates from a prototype. Assume an owner familiar with the Swift code and release system, a focused day of roughly **5–6 hours**, available fixtures and Intel/Apple Silicon/macOS 14 qualification environments, and AI assistance for implementation but human ownership of product decisions, QA, and support.

| Deliverable | Estimated focused effort | Included boundary |
|---|---:|---|
| Existing-tool workflow comparison | **1–2 days** | Establish whether the #80 gap still exists. |
| Experimental Codex Markdown export | **2–4 days** | Explicitly identified session, limited experimental distribution, synthetic fidelity checks; no complete attachment archive. |
| Dependable packaged “archive this Codex chat” feature | **5–10 days total** | Native-ID resolution, compressed/active histories, explicit failures, output policy, agent instructions, signed installation and upgrade checks. |
| Full planned three-provider macOS CLI | **20–40 days total** | Current shared readers; strict read contract; indexing/freshness/deletion behavior; cache migrations; JSON/errors; GUI regressions; both architectures; macOS 14; release/update integration. |
| macOS TUI after a stable CLI | **Add 10–20 days** | Go client adaptation, preview/navigation UX, cancellation, terminal behavior, process/error handling, installation and compatibility checks. |

The export and broad-CLI totals include their earlier implementation work; do not add every row together. A broad CLI plus TUI is therefore approximately **30–60 focused days**, excluding Linux and an open-ended support tail. At 2.5 focused days per week, the broad CLI alone spans roughly **8–16 calendar weeks**.

The low end of the export estimate depends on clean identity resolution and renderer extraction. Missing qualification environments, unexpectedly coupled dependencies, or newly changed provider formats push estimates upward. The reviewed plan's final `PLAN READY` judgment establishes technical coherence, not elapsed implementation time or demand. [Live `docs/plans/2026-10-23-macos-cli-architect-review-r3.md:32–50`.]

Long-term, the owner would own parser fixtures and drift, command/schema compatibility, agent instructions, cache/version/freshness support if included, code signing and installation, documentation, and GUI regression risk. Taking the TUI also means owning Go dependencies, terminal-specific behavior, performance, and CLI/client compatibility. An absent contributor is not a staffing plan.

### License, attribution, and handling the open PR

The exact P77 fork contains an [MIT license](https://github.com/shurrman/agent-sessions/blob/4b546dccceaa5862d36453979100026ca37d7353/LICENSE). MIT permits copying, modification, merging, and distribution while retaining the copyright and permission notice in copies or substantial portions. An unmerged PR does not cancel that license; ordinary reuse does not require a new permission grant. GitHub's contribution terms also generally place contributions under a repository's license, subject to a separate applicable agreement. Retain applicable dependency notices when redistributing dependencies. [License and GitHub terms checked October 24/25.] genui{"citation":{"refs":["turn11view2","turn20view4"]}}

**Attribution etiquette goes beyond the minimum license condition.** Preserve authorship when adopting original commits. For new owner-authored ports, identify shurrman's contribution, PR #77, and relevant commits in the commit body/PR description and appropriate release acknowledgments. Preserve existing notices; do not imply the contributor endorsed the new direction or accepted maintenance. The repository's owner-author convention for new work is not a reason to erase the origin of adapted work. [`CLAUDE.md`; P77 license.]

**Recommended PR disposition:** thank the contributor for the proposal and useful groundwork; explain that the current decision is to validate a narrow macOS export job, without committing to TUI/Linux ownership; then close #77 as a proposal outside current scope, or supersede it with a concrete narrow follow-up if one is actually opened. Close or supersede the companion consistently if its bounded-read work is not being pursued. Link the preserved ideas and successor work, and leave room for a separately maintained terminal effort.

There is no need to wait indefinitely for an answer, and no basis to label the contributor irresponsible or the project abandoned. I have not posted, closed, or changed either PR.


## 8. Critique of the existing Claude evaluation

I formed the recommendation above from the product evidence, public issues, current alternatives, and source before reading the Claude evaluation. We converge on holding the broad plan, but several of its supporting claims and proposed next steps need correction.

**E** below refers to live `docs/plans/2026-10-24-cli-product-evaluation.md`.

### Where I agree

The evaluation correctly separates the #80 export job from paginated reading, rejects architecture approval as a build mandate, identifies the growing competitive overlap, and recognizes the support burden of a second cache and a TUI without committed ownership. Its preference for validation before the six-slice plan is sound. [`E:7–13,89–117,130–150`.]

### Where it is wrong, overconfident, or incomplete

1. **Its Codex-export gap is overstated and internally inconsistent.** The jobs table treats claude-code-log as Claude-only, while its own alternatives table notes Codex beta support. Released 1.7.0 confirms that support. This does not prove the exact job is solved, but it changes the first experiment: test the requester's existing tool before assuming Agent Sessions must fill a missing capability. [`E:21–25,54–68`; [tagged README](https://github.com/daaain/claude-code-log/blob/1.7.0/README.md).]

2. **“No demand, no maintainer” exceeds the evidence.** There is no demonstrated TUI adoption and no commitment from the contributor. A lightly observed release cannot establish no demand, and a Mac-focused issue tracker under-samples Linux/SSH users. The owner can choose to maintain it, but would then be accepting an unvalidated cost. [`E:35`; PR/release evidence in section 4.]

3. **The app-database shortcut is a hypothesis, not an inexpensive validated design.** Reading it directly may be appropriate for installed GUI users. However, the normal database initializer mutates state, the corpus is sampled, freshness depends on GUI ingestion, and schema compatibility alone does not establish identity correctness or complete coverage. “One schema-version check” substantially understates those obligations. [`E:99–117`; `AgentSessions/Indexing/DB.swift:136–159,419–470`; `AgentSessions/Search/SearchIngestService.swift:203–287`.]

4. **Excluding Linux does not remove the main reasons for a headless boundary.** Avoiding UI initialization, making error behavior testable, and sharing qualified readers matter on macOS too. The particular package mechanism can be debated, but current SwiftUI/AppKit and app-factory coupling remains real. [`E:102–109`; descriptor/registry evidence in section 7.]

5. **Its first implementation grows beyond the evidence.** Gate 1 proposes Codex and Claude plus both export and bounded read. The concrete unmet-job hypothesis is current-Codex readable export. Adding a second provider and a second output contract before that succeeds makes the experiment less informative and more expensive. [`E:154–169`.]

6. **Its build gate conflates confirmation, personal utility, and adoption.** Another affirmative response from #80 or several owner uses can justify a capped experiment. They do not establish that a supported retrieval interface is worth maintaining. Conversely, owner utility can justify a small open-source convenience feature without claiming broader product-market fit. Keep those decisions explicit. [`E:130–150`.]

7. **It overinterprets native memory and session-ID evidence.** A recorded `memory_citation` example is evidence of a capability, not its prevalence, quality, or coverage of this job. An environment variable also does not prove it resolves the correct local artifact through concurrent/resumed sessions; current app IDs can differ from provider IDs. The suggested cwd-list fallback must not silently choose among multiple sessions. [`E:39–40,175–181`; `docs/backlog.md:1390–1408`; current identity code cited above.]

8. **It leaves material owner-alone questions unresolved.** The report needs an explicit reuse map, shipping effort with assumptions, ongoing ownership, and licensing/credit treatment. It also needs to test the complete invocation-to-saved-artifact workflow, not merely show that a parser or a skill exists. Sections 6–7 supply those missing decision inputs.

A further caution: if sampled search misses relevant conversations, that alone does not establish that ad hoc raw-file search inside `read` is the right remedy. The failure might be discovery, corpus coverage, ranking, or a poor query. Measure the task failure before selecting the implementation. [`E:175–183`.]

## 9. Unknowns that matter

| Unknown | Evidence that would resolve it |
|---|---|
| **Does #80 still have an unmet job after released Codex support in their existing tool?** | Run the complete current-chat workflow against that release: identify the correct session, operate with the GUI closed, save readable output, and report failures honestly. |
| **How often do existing users need agent-invoked export or cross-session retrieval?** | A short owner diary for personal utility; voluntary task-specific repeat-use reports for a supported feature. The current survey cannot supply this frequency. |
| **What does “archive” need to preserve?** | A concrete acceptance example covering prompts/responses, tools/errors, metadata, images/attachments, and active-session boundaries. Distinguish readable text preservation from a portable lossless package. |
| **Can current-chat identity be resolved reliably?** | Fixtures and selected real-world checks for native IDs versus path-derived IDs, compressed histories, concurrent sessions, resumes, custom roots, and stale invocation environments. Fail on ambiguity. |
| **Can a narrow export avoid most extraction and packaging cost?** | A capped spike on current main that extracts rendering, preserves strict parse outcomes, and demonstrates an installable helper. This is the largest uncertainty in the 5–10-day estimate. |
| **Would GUI-cache retrieval be accurate and fresh enough for an installed-user CLI?** | Known-answer retrieval cases comparing current source files with sampled indexed content, cold/stale caches, root changes, and supported schema versions. |
| **Is there a TUI/Linux audience with an unmet recurring job?** | Voluntary evidence of repeated terminal tasks, a concrete failure of current tools, and a credible ownership commitment. Existing download counts cannot resolve this. |
| **What maintenance budget will the owner actually accept?** | A deliberate capacity allocation, followed by logged support/release/drift work during a limited preview. Treat the reserve in section 5 as a scenario until measured. |
| **Would the contributor prefer a different future role?** | A reply if they choose to give one. This could change collaboration, but is not required to use MIT-licensed work respectfully or to make a macOS scope decision. |

The important external correction is that Codex export already has a released alternative; the important repository finding is that complete export can potentially reuse existing rendering without adopting the full retrieval platform. That combination warrants a small comparison and, only if it exposes a concrete gap, a bounded experiment.

VERDICT: VALIDATE FIRST