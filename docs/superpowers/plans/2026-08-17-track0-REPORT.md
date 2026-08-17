# Track 0 — Maintenance Tooling (steward program)

Date: 2026-08-17 · Branch: `main` (nothing committed) · Plan:
`docs/superpowers/plans/2026-08-17-steward-program-PLAN.md`

Two deliverables: Grok's parser degrades instead of failing, and a steward can
re-verify one agent with one command.

---

## Task A — GrokSessionParser: alert, not crash

Grok was the only one of the thirteen parsers that decoded through `Codable`.
`grep -n "JSONDecoder\|Decodable\|Codable" AgentSessions/Services/Grok*.swift`
found exactly three lines, all in `GrokSessionParser.swift`, all one decode site:

| Site | Before | After |
|---|---|---|
| `private struct Sidecar: Decodable` (+ `Info: Decodable`, `CodingKeys`) | Snake-case keys mapped by `CodingKeys`; the struct decoded as a unit | Plain struct with `init(object: [String: Any])`; each field read by literal key from a `JSONSerialization` dictionary |
| `readSidecar(for:)` → `try? JSONDecoder().decode(Sidecar.self, from: data)` | Any field arriving with a type the struct did not expect threw; `try?` swallowed it and returned `nil`, so the session lost **id, cwd, title, model, both timestamps, reasoning effort and parent id at once** | `try? JSONSerialization.jsonObject(...) as? [String: Any]` then per-field reads; a changed field costs exactly that field |
| `num_chat_messages` | `Int?` via the decoder, which accepted an integer or an exactly-representable double and threw on anything else | `(value as? NSNumber)?.intValue` with an explicit `is Bool` guard, so integer/double behave as before, a bool or string degrades to `nil` instead of destroying the sidecar |

No other call site was affected: `Sidecar` is `private` and referenced only inside
this file, so nothing outside needed the type to stay `Decodable`. Behaviour on
well-formed input is unchanged — every pre-existing Grok test passes untouched,
including the byte-level ones (`testTimestampsComeFromSidecar`,
`testLightweightParseCountsNonMetaEventsWhenNotTruncated`). The transcript side
already read dictionaries and was not touched, so the `chat_history.jsonl` +
`summary.json` sidecar join is exactly as it was.

### Degraded results, pinned

Four new tests in `AgentSessionsTests/GrokSessionParserTests.swift` state exactly
what "graceful" means, rather than only that nothing throws:

- `testUnknownNewFieldsAreIgnored` — a session with vendor-added keys at every
  level (top-level record, content part, tool call, sidecar, `sidecar.info`)
  produces the *same* id, title, model, cwd, both timestamps, event count, event
  ids, kinds, texts and tool names as the same session without them.
- `testSidecarFieldOfTheWrongTypeCostsOnlyThatField` — `created_at` arrives as an
  object, `num_chat_messages` as a string, `reasoning_effort` disappears.
  Result: `startTime == nil` and `reasoningEffort == nil`; id, title, model, cwd,
  `endTime` and the events all survive. This is the case that used to erase the
  whole sidecar.
- `testUnusableSidecarStillYieldsATranscriptSession` — `{}`, `[]` and
  `not json at all` each still yield a session; identity falls back to the
  directory name and the title to the first genuine prompt.
- `testTranscriptRecordsMissingRequiredFieldsDegradeInPlace` — a record with no
  `type` is skipped and contributes nothing, while later records keep their own
  physical line index (event ids stay `1-u, 2-t0, 3-m, 4-r`, which
  `SessionInlineImageMapper` depends on); a contentless assistant still emits its
  tool call; an assistant with nothing at all becomes one meta placeholder; a
  `tool_result` without `content` keeps its correlation id with a nil output.
  Nothing throws past the session boundary and the non-meta count is 3.

---

## Task B — `scripts/steward_check.py`

CLI shape follows `agent_watch.py` (argparse, `main(argv) -> int`,
`raise SystemExit(main(sys.argv[1:]))`) with the agent as a positional, since the
whole point is that a steward types one short thing:

```
./scripts/steward_check.py grok
./scripts/steward_check.py --list-agents
```

### Design decisions

1. **The scan is the real weekly scan, driven, not reimplemented.** `_scan()`
   writes a filtered copy of `docs/agent-support/agent-watch-config.json`
   containing only the requested agent (with `cadence.weekly` forced true) and
   calls `agent_watch.main(["--mode", "weekly", ...])` on it, then reads the
   `report.json` it produced. The alternative — calling the fingerprint helpers
   directly — would have meant a second copy of `main`'s twelve-branch
   `local_schema.kind` dispatch (sqlite, markdown, storage-tree, wire, …) to keep
   in sync. This tool has already been bitten twice by private copies of shared
   maps drifting, so nothing is copied: `MATRIX_KEY_FOR_AGENT` is imported and
   `_known_agents()` is the intersection of the config with it.
2. **Verdict reading is deliberately narrow.** Only
   `evidence.schema_matches_baseline` and `evidence.schema_diff` decide the exit
   code. A steward with a flaky network or a failing upstream probe still gets a
   usable format answer instead of an alarming amber verdict about monitoring
   infrastructure that is not theirs.
3. **Reporting is a pure function of the report.** `_report(agent, result, out_dir)`
   takes the result block and returns the exit code, which is what makes the exit
   codes testable without a CLI, sessions, or a network.
4. **Never writes a baseline.** Drift prints, writes a sample and an issue body;
   rebuilding a fixture stays `rebuild_stage0_baseline.py --emit`, a maintainer job.
5. **Public names resolve.** `STEWARDS.md` says "Grok CLI" and "Claude Code", so
   `_resolve_agent` accepts the matrix key as well as the internal key — derived
   from `MATRIX_KEY_FOR_AGENT`, not a hand-kept alias list.
6. **Exit codes:** 0 clean, 1 drift, 2 cannot check (no CLI / no sessions / no
   baseline / unknown agent). Output is plain sentences, no emoji, no jargon
   verdict strings.

### Redaction, and the second line of defence

Records are harvested with the same greedy set cover `rebuild_stage0_baseline`
uses (`_record_buckets` against a probe file outside the fixture tree) and
redacted with `rebuild._redact` itself — the identical trimming that produces
committed fixtures, including per-agent `_NESTED_OPAQUE_KEYS` dropping. Grok's
sidecar is handled separately, because `summary.*` buckets can never appear on a
transcript record: when the drift is in the sidecar the redacted `summary.json`
is written beside the sample, in fixture layout.

Redaction alone is not trusted. `_redaction_leaks()` re-scans the finished text
for emails, macOS/Linux/Windows home directories, key-shaped strings, IPv4
addresses, any run of 32+ id-ish characters (tokens, hashes, UUIDs), and the
running user's literal `$HOME`. **If anything matches, no file is written** and
the issue body says a sample was withheld and why — an almost-clean file about to
be pasted into a public issue is worse than no file.

### Redaction verification evidence

End-to-end, against a synthetic `$HOME` holding a Grok session whose every
value-bearing position carried planted PII (`/Users/alexm/secret` as the bucket
name, cwd, tool argument and a new nested field; `alexm@example.com` in prompt
text and title; `sk-ABCDEFGH12345678` as a tool result; a real-shaped session
UUID) plus two kinds of drift (a new nested key on `assistant`, a wholly new
record type, and a new `summary.json` key):

- The run exited 1 and named all three changes in plain words.
- Written sample (`grok-drift-sample.jsonl` + `summary.json`), scanned
  afterwards: `leaks: []`, and each of `alexm`, `@example.com`, `/Users/`,
  `sk-`, `secret` independently absent. Structure survived — `brand_new_record`,
  `brand_new_assistant_key`, `nested_new` and `brand_new_summary_key` are all
  still visible as keys, which is the whole point of the sample.
- `tool_calls[].arguments` came out `null` rather than placeheld, because
  `arguments` is in Grok's opaque-key set — correct: it is a tool's parameter
  object, not Grok format.
- Positive control: `test_leak_scanner_actually_fires` asserts the scanner *does*
  match each planted secret, so an empty leak list is evidence rather than a
  scanner that matches nothing.

The other three paths were also exercised against real machines/config, not
mocks: clean (`all good: grok format matches the baseline (5 sessions sampled)`,
exit 0), empty `$HOME` (no sessions, exit 2, names `~/.grok/sessions`), and empty
`$HOME` with `PATH=/usr/bin:/bin` (CLI not found, exit 2, names `grok --version`).

### Documentation

`skills/agent-session-format-check/SKILL.md` gained **§1f Steward Check** (what a
steward runs, the three exits, what it refuses to do, the withheld-sample rule,
and the maintainer side: the sample is already in fixture shape). §4a also gained
a short paragraph recording that Grok's parser is now tolerant like the rest, with
the two tests that pin it.

`docs/CONTRIBUTING.md`, `README.md` and `STEWARDS.md` belong to the concurrent
docs agent and were not touched here. Their drafts already reference
`./scripts/steward_check.py <agent>` and describe it accurately (redacted sample,
attach to an issue), so no correction is needed — **CONTRIBUTING linkage remains
the docs agent's to add.**

---

## Verification

| Check | Result |
|---|---|
| `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` | BUILD SUCCEEDED |
| `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/GrokSessionParserTests` | 16 tests, 0 failures (12 pre-existing + 4 new) |
| `./scripts/xcode_test_stable.sh` (full) | 2040 tests, 3 skipped, 0 failures |
| `python3 -m pytest scripts/tests -q` | 186 passed (175 pre-existing + 11 new) |
| `./scripts/steward_check.py grok` on this machine | exit 0, clean, 5 sessions sampled |

Nothing was committed, pushed, or branched.
