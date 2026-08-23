# Contributing to Agent Sessions

Agent Sessions can support another coding agent only when that agent writes readable
session history to disk. You do not need to be a Swift developer to help: reliable format
evidence and a sanitized fixture are often the hardest parts of an integration.

## Add an agent

Choose the contribution that fits what you can verify:

1. **Propose a source.** Open the
   [new-agent-source issue form](https://github.com/jazzyalex/agent-sessions/issues/new?template=new-agent-source.yml) with the
   agent's official project, tested version, storage path, and known capabilities.
2. **Contribute format evidence.** Add a small sanitized fixture and document how it was
   captured. Remove prompts, outputs, account identifiers, tokens, credentials, private
   paths, private repository names, private remote URLs, and URLs copied from session data.
3. **Implement the source.** Follow
   [Adding a session source](adding-a-session-source.md), or give the
   [AI-agent implementation brief](prompts/add-an-agent-source.md) to your coding agent.

Before sending the repository to a coding agent, run its cheap read-only preflight from the
brief: create an empty temporary folder and give it one sentence such as “Use exactly one
read-only directory-listing tool call on this empty folder, then reply READY; do not write or
inspect anything else,” with a 20-second or minimal-cost limit supported by that agent. This
checks that the model can act and can access the bounded workspace; an installed CLI can still
have expired authentication, an ineligible account tier, or no usable model budget. Do not use
the repository or a real session as the preflight input.

Every source is merged as ordinary reviewed code. Agent Sessions does not download source
plugins, execute contributed agent code, or infer support from an installed binary.

### Most-wanted evidence: Cline

Among the two locally reviewed new candidates on 2026-08-17, [Cline](https://github.com/cline/cline)
had the larger public GitHub-star signal than [Qwen Code](https://github.com/QwenLM/qwen-code).
That dated comparison is a reproducible prioritization signal, not usage telemetry or a claim
about every coding agent. Cline's [CLI reference](https://docs.cline.bot/cli/cli-reference)
documents session history and resume,
but this checkout has no local Cline installation or publishable fixture. If you use the
current Cline CLI on macOS, the most useful contribution is a new-agent-source proposal that
verifies the local storage root, SQLite schema/version, CLI-versus-IDE source marker, deletion
behavior, and a synthetic or fully sanitized session fixture. Do not implement from public
documentation alone.

## Become a steward

Adding an agent is one job. Keeping it working is another, and it is the one that decides
whether support survives. Agents change their session formats without warning, and the only
reliable evidence is a real installation with real sessions in it.

A **steward** looks after one agent. You get pinged two or three times a year, run one
command against your own sessions, and say whether the format still reads correctly. That
is about ten minutes. If the format moved, you attach the redacted sample the tool produced.

The command is:

```bash
./scripts/steward_check.py <agent>
```

It checks your agent's sessions against the recorded baseline and, if the format changed,
produces a redacted sample you can attach to an issue.

What stewarding is not: no commit rights, no code, no review duty, no response deadline. You
never send a real transcript — the tool redacts first and you choose what to attach. If you
go quiet, the agent moves back to best-effort and nothing bad happens.

What you get: named credit in [STEWARDS.md](../STEWARDS.md) and on the project site's
support page, with a dated public record of each verification.

To adopt an agent that is already supported, use the
[steward signup form](https://github.com/jazzyalex/agent-sessions/issues/new?template=steward-signup.yml). If you are proposing a
new agent, the [new-agent-source form](https://github.com/jazzyalex/agent-sessions/issues/new?template=new-agent-source.yml) and
the [agent-source PR template](../.github/PULL_REQUEST_TEMPLATE/agent-source.md) both ask
whether you are willing to steward it afterwards. Saying yes there is enough.

## Evidence required

Before implementation, establish all of the following:

- The agent and exact version that produced the session.
- The producer surface: CLI, IDE extension, desktop app, daemon, or a shared store. Prove
  which records belong to the source being added so an IDE database is not silently
  advertised as CLI history, or vice versa.
- The default macOS storage path and whether users can override it.
- The file or database format, stable session identity, and update signal.
- At least one sanitized positive fixture and one malformed or unsupported fixture.
- Which capabilities are actually present: transcript, tools, images, subagents, resume,
  deleted-session recovery, and project metadata.
- The exact resume command, if any, established from the installed CLI's help and reader
  behavior. Verify which canonical active/archive locations and default/custom storage roots
  it resolves; copied and launched commands must select the same store the app displayed.
  Call resume **verified** only after a local disposable end-to-end run. If authentication
  blocks that run, an implementation may remain explicitly **untested** only when installed
  reader evidence and hermetic command/path tests establish its behavior. Unsupported and
  untested capabilities must be stated explicitly in every public support claim.

Do not commit a real transcript or an entire production database. If a minimal fixture
cannot be made safe to publish, describe the schema in the proposal and ask a maintainer
how to proceed.

## Development setup

Requirements:

- macOS 14 or later
- A current Xcode installation
- A checkout or fork based on current `main`

Build the app:

```bash
xcodebuild -project AgentSessions.xcodeproj \
  -scheme AgentSessions \
  -configuration Debug build
```

Run the stable test workflow:

```bash
./scripts/xcode_test_stable.sh
```

New Swift files must be added with `scripts/xcode_add_file.rb`; the source guide contains
the exact commands. Do not hand-edit the Xcode project unless the guide explicitly requires
it.

## Testing your source against your own sessions

A green build and a green suite prove the code compiles and the fixtures parse. They do not
prove the app reads *your* agent. Only you can check that, because in most cases the
maintainer does not have the agent installed — that is usually the whole reason your
contribution matters.

Do this once before marking a PR ready, and again if a reviewer changes your parser.

**1. Launch a build you did not test with.**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions \
  -configuration Debug -derivedDataPath .deriveddata-run build
open .deriveddata-run/Build/Products/Debug/AgentSessions.app
```

Use a derived-data path **separate from the one `xcodebuild test` writes to**. Test runs
re-sign the bundle and embed the XCTest runner; launching that copy gives you a live process
with no window and no Dock icon, which looks exactly like a catastrophic bug and is not one.

**2. Make sure your source is switched on.** If your descriptor says
`defaultEnabled: .whenAvailable` — the recommended setting for a new source — the app leaves
your agent off until it detects one. So when the rows are missing, check Settings → your
agent's pane before you suspect the parser. That pane is also where the
storage-root override lives, so you can point the app at a copy of your sessions instead of
your live store.

**3. Answer these. Each one has been wrong in a shipped source at least once.**

- Sessions appear in the list, and the count looks right for what you have on disk.
- Titles are the ones you would recognise, not file names or `Untitled`.
- Opening a session renders user turns, assistant replies and tool calls — with no blank
  turns and nothing obviously missing from the middle.
- Timestamps and durations are plausible; nothing sits in 1970.
- Search finds a distinctive string you can see on screen in that transcript.
- The has-commands filter keeps sessions that used tools and drops the ones that did not.
- Analytics counts your agent when it is enabled and stops when it is not.
- Copy Resume Command produces something you can paste into a terminal.
- **Resume actually reopens the session.** This is the one that most often cannot be
  verified by anyone but you, and the one most often assumed rather than run.

**4. Report what you found, including the boring parts.** "All nine pass" is a useful
result. So is "eight pass, timestamps are off by an hour" — that is a real finding, not a
failure on your part.

Never paste a real transcript, an API key, or a private file path into an issue or a PR.
Screenshots are welcome only when they show source-specific behaviour and contain nothing
private; you decide what is on screen.

## Pull requests

Start with a draft PR and use the
[agent-source PR template](../.github/PULL_REQUEST_TEMPLATE/agent-source.md). Keep the PR
limited to one source and include:

- Tested agent and app versions.
- Sanitized fixture provenance.
- A capability table that distinguishes verified, unsupported, and untested behavior.
- Exact build and test results.
- Known format limitations and failure behavior.
- Screenshots only when they demonstrate source-specific UI behavior and contain no private
  session content.

Passing CI is necessary but not sufficient. Reviewers will compare claims against the
parser, fixtures, discovery paths, search behavior, analytics metadata, and resume gates.

## Other contributions

For fixes unrelated to a new source, keep the PR focused, explain the user-visible failure,
and include a regression test where practical. User-visible changes also need an Unreleased
changelog entry and a note in the current monthly summary.
