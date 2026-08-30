---
title: "AI-agent brief: add a source"
last_modified_at: 2026-08-29
---
# AI-agent brief: add a source to Agent Sessions

Before copying the brief, the human should create an empty temporary folder and send the
coding agent a one-sentence preflight with a small time or cost bound: use exactly one
read-only directory-listing tool call on that folder, then reply `READY`, with no writes or
other inspection. Continue only if model access and that bounded workspace access succeed;
an installed `--version` command does not prove that authentication, account eligibility, or
budget still works.

Then copy this brief into Codex, Claude Code, or another coding agent after replacing the
values in angle brackets. The human contributor remains responsible for inspecting fixtures,
approving repository writes, and publishing the pull request.

```text
Goal: add <AGENT NAME> <VERSION> as a session source to Agent Sessions.

Repository: current checkout (resolve locally; do not echo its absolute path)
Verified producer surface: <CLI / IDE / DESKTOP / DAEMON / SHARED STORE>
Verified local session root: <~/-RELATIVE PATH OR "fixture only"; do not echo its expansion>
Sanitized fixture location: <REPOSITORY-RELATIVE PATH OR "not created yet">
Official upstream project: <URL>

Authority and safety:
- Work only in the named checkout and preserve unrelated changes.
- Read AGENTS.md, docs/CONTRIBUTING.md, and this brief before Stage 1. Read the longer
  docs/adding-a-session-source.md contract only after Stage 2 is authorized.
- Do not create, switch, rename, or delete branches or worktrees unless I explicitly ask.
- Do not commit, push, open a PR, post upstream, or start a model-backed/session-producing
  run of the new agent unless I explicitly authorize that action. Read-only `--version` and
  `--help` probes are allowed in Stage 1.
- Never print or commit raw prompts, outputs, credentials, tokens, account identifiers,
  private repository names, private remote URLs, URLs copied from session data, or full
  production databases. The public official upstream URL above is allowed.
- The Agent Sessions app must remain read-only toward the agent's storage and must not make
  network requests to discover or parse sessions.

Stage 1 - prove the source:
1. Verify the installed binary and version without authenticating or starting a paid run.
2. Locate the session root from local evidence and official upstream documentation.
3. Prove which producer surface writes the records. If CLI, IDE, desktop, and daemon runs
   share a store, identify a stable discriminator or state that support is for the shared
   store. Do not label all records as CLI history merely because a CLI can open the store.
4. Inspect only the minimum local records needed to identify the schema, stable session ID,
   timestamps, project metadata, message/tool representation, update behavior, and deletion
   behavior. Prefer keys, types, counts, and documented CLI metadata; do not print a session
   list if it includes stored prompts or titles.
5. Create a minimal synthetic or thoroughly sanitized fixture. Add a negative fixture for a
   malformed or unsupported record.
6. Write an evidence table for transcript, tools, reasoning, images, subagents, resume,
   project metadata, and deleted-session recovery. Mark each verified, unsupported, or
   untested. Do not infer a capability from another agent or from product copy.
7. If there is no readable local session history or no safe fixture can be produced, stop
   and prepare the new-agent-source issue instead of implementing speculative support.

Stage 2 - implement:
1. Read docs/adding-a-session-source.md completely, then follow every current step and
   semantic switch it enumerates.
2. Keep discovery, parsing, settings, CLI probing, and adapter code source-local wherever
   the registry permits it.
3. Route availability through AvailabilityContext. Do not read the developer's real home or
   PATH in tests.
4. Preserve persisted key strings, source values, archive folder names, and search source
   values as explicit literals.
5. For shared databases, carry stable identity and an authoritative identity snapshot; a
   read failure must never be interpreted as an empty source.
6. Implement resume only after verifying the exact installed CLI syntax, canonical active and
   archive path shapes, and default/custom-root behavior. Reuse one normalized-root-aware path
   classifier for discovery and resume gates. Ensure copied and launched commands select the
   same storage root the app displayed; otherwise declare resume unsupported for that session.
   Make Copy Resume and launch use the same probed capabilities for the exact default or custom
   binary; a session ID alone does not prove `--resume` support.
   Call resume verified only after a disposable end-to-end run. If authentication blocks that
   run, label the integration untested in public support data and the handoff, even when
   installed reader evidence and hermetic command/path tests justify implementing it.
7. Add parser, discovery, registry, search, analytics, preference, and capability tests
   appropriate to the source. Expectations must be independent goldens, not values derived
   from the implementation under test.
8. Add all Swift files through scripts/xcode_add_file.rb.
9. Update README.md, docs/CHANGELOG.md, the current docs/summaries entry,
   docs/agent-support/agent-support-matrix.yml, and docs/agent-support/public-agents.json only
   with claims established by fixtures or local verification.

Stage 3 - verify and hand off:
1. Run git diff --check.
2. Run the AgentSessions Debug build.
3. Run ./scripts/xcode_test_stable.sh.
4. Review the final diff for private data, unrelated changes, generated artifacts, and
   unsupported marketing claims.
5. Prepare, but do not publish, a draft PR body using
   .github/PULL_REQUEST_TEMPLATE/agent-source.md. Include exact test totals and limitations.
6. Report the changed files, evidence used, commands run, and anything not verified.
```

## What the human should check

Before allowing a push or PR:

- Open every fixture and confirm that it contains no personal or confidential content.
- Compare the capability table with the implementation and public copy.
- Confirm the agent's license and terms permit publishing the fixture or synthetic schema.
- Confirm the full build and tests were run from the final diff.
- Prefer a draft PR until a maintainer verifies the source against another installation.
