# Session Rescue — Design

**Date:** 2026-08-06
**Status:** **APPROVED — build the rescue tier.** Scope cut twice during review (see Verdict).
**Problem:** Claude Code hard-deletes session transcripts after ~30 days. Agent Sessions can already
survive that, but only for sessions the user manually starred in advance.

> ## Verdict (2026-08-06)
>
> **Build the automatic rescue tier on the existing `SessionArchiveManager`. One week.
> No compression in v1. No git remote, ever, in the form originally proposed.**
>
> The feature survives an unusually hostile prior-art record (§2: every transcript-backup tool
> ever shipped sits at 0–6 stars; the closest analog has 14 installs) for two reasons only:
> it is backup-as-a-*feature* inside an app opened daily for another purpose rather than
> backup-as-a-product with no acquisition motion, and the expensive machinery already exists
> and is proven. As a from-scratch build the recommendation would be **don't**.
>
> **Three corrections recorded so they are not re-argued:**
>
> 1. **Images are not the disk problem.** Base64 payloads are ~4.5% of the corpus (§3).
>    The bulk is tool-output text. Any design premised on stripping images is solving nothing.
> 2. **A private GitHub repo is the wrong substrate and is killed, not deferred.** Encrypted
>    blobs in a private repo sit at the mercy of soft quotas and push-rate limits, LFS is
>    excluded by our own volume numbers, and a future paid tier would be AS-owned storage
>    (R2/S3 + client-side age encryption) into which *none* of the git plumbing survives.
>    It is throwaway work on the free path and the paid path simultaneously.
> 3. **Compression is the most invisible work in the proposal and is cut from v1.**
>    Revisit when a real Archives directory gets large (§7).
>
> **One open issue, deliberately unresolved (§5.2):** the original brief named two gaps —
> no auto-save, and Save costing disk instead of saving it. **v1 closes the first and makes
> the second worse.** Rescue keeps what Claude would have deleted, so the archive grows without
> bound (~14 GB/year uncompressed on this machine's usage). The review's premise that rescue-tier
> steady state is "small by design" does not survive contact with the measured numbers. Compression
> would change the slope, not the direction. Bounding the tier needs its own decision and is not
> guessed at here.

---

## 1. Problem

Claude Code deletes chat transcripts from `~/.claude/projects/` once they pass
`cleanupPeriodDays` (default 30). The delete is a straight `unlink()` — no trash, no grace
period, no recovery command — and it runs at CLI startup. Reported repeatedly and unresolved:
[#64999](https://github.com/anthropics/claude-code/issues/64999),
[#62476](https://github.com/anthropics/claude-code/issues/62476),
[#59248](https://github.com/anthropics/claude-code/issues/59248),
[#62959](https://github.com/anthropics/claude-code/issues/62959), and covered by
[The Register](https://www.theregister.com/ai-and-ml/2026/06/30/claude-code-users-complain-their-chat-records-are-being-mysteriously-wiped-out/5264673)
on 2026-06-30. Anthropic's stated rationale is not retaining source code and credentials on disk.

Two known traps in the vendor behaviour:

- Deletion keys on file **mtime**, not real last-activity, so raising the setting under-protects
  ([#62476](https://github.com/anthropics/claude-code/issues/62476)).
- Setting `cleanupPeriodDays: 0` does not disable cleanup — transcripts stop being written at all.

Claude **Desktop** has a separate failure: history wiped by an app update with no server-side
backup and no export ([#64403](https://github.com/anthropics/claude-code/issues/64403)). There is
no native server-side sync ([#56038](https://github.com/anthropics/claude-code/issues/56038) open).

Agent Sessions already survives all of this — but only for manually starred sessions. **Selection
happens before the user knows which session mattered**, which is the same failure mode as having
no protection at all for the session you didn't think to star.

## 2. Prior art (measured 2026-08-06, GitHub API — not blog claims)

Transcript backup and sync, every entrant:

| Tool | Stars | State |
|---|---|---|
| DazzleML/Claude-Session-Backup | 6 | active |
| gammons/ai-session | 4 | abandoned Feb 2026 |
| markmatsu/claude-logkeeper | 1 | — |
| npow/session-sync | 1 | abandoned |
| neonplants/claude-code-session-archiver | 0 | abandoned Oct 2025 |
| "Agent Sessions Sync" (VS Code ext, Claude+Codex+Cursor → private GitHub repo) | **14 installs** | — |

Viewers and search, same query date:

| Tool | Stars |
|---|---|
| kenn-io/agentsview | 4,720 |
| jhlee0409/claude-code-history-viewer | 2,016 |
| simonw/claude-code-transcripts | 1,654 |
| Dicklesworthstone/coding_agent_session_search | 1,047 |
| **jazzyalex/agent-sessions** | **761** |

Vendor and adjacent movement, all within the last ten weeks:

- **VS Code 1.123** (2026-06-03, GA 2026-07-01) shipped GitHub-backed chat session sync plus
  `/chronicle` natural-language history query. Microsoft solved this natively for Copilot.
- **Codex CLI v0.136** (2026-06-01) shipped native `codex archive`. Codex does **not** auto-purge.
- **MemoryPlugin Sync** launched 2026-08-05 — macOS, same three agents, $89–180/yr. A memory
  product rather than backup, but the same data on the same platform.

**Reading:** the category has a demonstrated ceiling, and the word "backup" is doing the damage.
Nobody goes looking for session backup, because the pain is retrospective — by the time a session
is gone there is nothing to install. This ships as a safety net inside an existing daily-use app,
or it does not ship.

## 3. Measured facts (this machine, 2026-08-06)

| Corpus | Size |
|---|---|
| `~/.claude/projects` | 1.2 GB / 2,363 transcripts |
| `~/.codex/sessions` | 3.6 GB |
| `~/.codex/archived_sessions` | 1.5 GB |
| **total** | **6.3 GB** |
| base64 image payload (Claude + Codex) | ~278 MB — **4.5% of total** |
| `Claude/local-agent-mode-sessions` | 142 MB, directory-shaped sessions |
| `Claude/claude-code-sessions` | 8.2 MB, contains `deleted_<uuid>` tombstones |
| `Claude/vm_bundles` | 6.9 GB — VM images, not history, out of scope |

Compression on a 348 MB sample: gzip -9 → 2.5x, zstd -19 → 3.8x.

Claude Desktop transcripts are **plain files on disk**, not locked in Electron IndexedDB. Full
auto-save there costs ~150 MB — two orders of magnitude cheaper than the CLI corpus.

## 4. What already ships

`AgentSessions/Services/SessionArchiveManager.swift` (~1,080 lines). Starring copies upstream files
**verbatim** to `~/Library/Application Support/AgentSessions/Archives/<source>/<id>/` as
`meta.json` + `manifest.json` + `data/`. Staged copy, consistency re-scan, atomic commit with
backup-and-rollback. Directory-shaped upstreams handled via `upstreamIsDirectory` and per-entry
manifests.

Deletion survival already works: `ensureSynced` sets `upstreamMissing` and keeps the archive;
`mergePinnedArchiveFallbacks` re-injects archive-only sessions into the list; `ClaudeArchiveRestore`
owns restore-to-upstream. Because copies are verbatim, restored sessions remain **fully resumable**.

`shouldMarkFinal` flips a session to `.final` after 30 minutes (configurable) of upstream quiet —
the "safe to act on" clock, already computed and already user-facing.

**This design adds a trigger policy on top. It does not add storage machinery.**

## 5. Design

### 5.1 Tiers

| Tier | Applies to | Trigger | Cost |
|---|---|---|---|
| **Manual** | all agents | user stars — unchanged | user's choice |
| **Full auto** | Claude Desktop: `local-agent-mode-sessions`, `claude-code-sessions` | every session, on `.final` | ~150 MB, slow growth |
| **Rescue** | Claude CLI: `~/.claude/projects` | mtime crosses `effectivePeriod − margin` | ~zero until sessions age out |

Codex gets neither automatic tier. It does not auto-purge, `codex archive` is native, and its
5.1 GB is the last thing worth duplicating. Manual starring remains available.

All other agents: manual only, unchanged.

### 5.2 Disk cost — stated honestly

**Nothing is ever deleted by Agent Sessions.** There is no destructive code path, no confirmation
dialog, and no new class of data-loss bug. That is the safety story, and it holds.

**The space story does not hold, and this design does not deliver it.** Rescue keeps sessions that
Claude would have destroyed, so the archive accumulates without bound at the rate the user
generates sessions. Measured against this machine: `~/.claude/projects` holds ~1.2 GB, which is
roughly **one 30-day window** of Claude CLI usage. Rescuing all of it implies on the order of
**~14 GB/year** uncompressed, growing forever. Compared to the status quo — where those bytes are
deleted and the disk is reclaimed — rescue *costs* disk rather than saving it.

This is the direct consequence of cutting compression (§7), and it should not be papered over:
even with compression at 3.8x the archive still grows (~3.8 GB/year), just more slowly.
Compression changes the slope, not the direction. Only a retention policy or an offload target
changes the direction, and both are out of scope here.

**Therefore v1 solves the auto-save gap and does not solve the disk gap.** Two consequences:

- The archive-size figure must be surfaced in Preferences from day one, not deferred, so growth is
  visible before it is a complaint.
- A bound on the rescue tier is the first follow-up to consider — either archive retention, or a
  substance filter so trivial sessions are never rescued. Deliberately left unresolved rather than
  guessed at; it needs its own decision.

The Desktop tier is additive too, but capped by construction (~150 MB) and therefore not a concern.

### 5.3 Liveness (the constraint that shapes everything)

Agent Sessions is a GUI app, not a daemon. A user who does not launch it for 33 days gets **zero
rescue**, and the casual, non-obsessive user is precisely who loses sessions. Mitigations, in
order of cost:

1. Run the rescue sweep **at launch**, early, before anything else can age out.
2. Default `margin` to **7 days**, not 3. Rescue archives are small; over-rescuing is nearly free
   and buys tolerance for irregular app usage.
3. A launchd helper is explicitly **out of scope** for v1 — scope creep, new failure modes,
   new permission surface.

Settings copy must state the limit honestly: *protects sessions while Agent Sessions is in use.*
Anything stronger is a promise the architecture does not keep.

### 5.4 Reading the retention period

Read the **effective** `cleanupPeriodDays`, not just `~/.claude/settings.json`. The settings
hierarchy includes managed settings and environment overrides; where multiple values resolve,
**take the minimum** and behave conservatively.

Clamp the margin so a short period cannot invert the logic:

```
margin = max(1, min(configuredMargin, effectivePeriod - 1))
```

A user on a 2-day period therefore gets "archive almost immediately," which is an acceptable
degradation — but a deliberate one, not an accident.

### 5.5 Urgency is computed from mtime

Because the vendor purge keys on mtime, rescue must key on mtime too. Using `endTime` or parsed
transcript timestamps will mis-rank exactly the sessions closest to deletion.

## 6. Failure modes

| Risk | Handling |
|---|---|
| **Mid-copy deletion race** — session vanishes between manifest build and `copySnapshot` | The real bite of the mtime-keyed purge. Path exists today but barely fires for manual starring; an automatic tier racing the purger exercises it constantly. Must degrade to a clean partial-or-skip, never a corrupt archive or a crash. Needs an explicit test. |
| App not launched for > retention period | §5.3 — launch sweep + 7-day margin; documented limitation |
| Desktop tombstones | Exclude `deleted_<uuid>` files from full auto-save |
| Desktop directory sessions carry workspace artifacts (355 `.md`, 141 `.ts`, 146 `.js`) | Already handled by `upstreamIsDirectory` + per-entry manifest; no new code |
| Archive growth from the Desktop tier | Capped by construction (~150 MB); surface archive size in Preferences |
| FDA / TCC | No new surface — `~/.claude` and `~/Library/Application Support/Claude` are not TCC-protected for the user's own process. The known dev-machine FDA flap is a bundle-id collision artifact, not a shipping concern |
| Duplicate work vs. manual stars | Rescue writes through the same `pin` path; existing archives are refreshed, not duplicated |

## 7. Explicitly out of scope

- **Compression.** Cut from v1. Revisit only when a real Archives directory gets large. If it
  returns: zstd **~12** (not 19 — encode at 19 is far too slow for background work and the size
  delta is a rounding error at these volumes), gated on FTS having indexed the transcript first,
  and any verification query against `index.db` must avoid `mode=ro` (WAL-committed rows are
  invisible to read-only opens).
- **Git remote / Stage 3.** Killed, not deferred. See Verdict.
- **Cloud storage tier.** If it ever becomes real, design it then on real object storage as an
  actual product — not reached by accident through git plumbing.
- **launchd background helper.** Out for v1; revisit only if telemetry shows launch-sweep misses.
- **Codex automatic tiers.**

## 8. Positioning

Do not use *backup*, *sync*, or *archive* in the headline. Every tool that led with those words is
in the ≤6-star table in §2. Lead with the villain and the catch:

> Claude Code deletes your session history after 30 days. Agent Sessions now catches sessions on
> their way to the shredder — automatic, local, still resumable.

In-app: one toggle, **Rescue**, on by default for Claude.

**Launch vehicle is a written piece, not a release note.** The forensic story is unwritten and we
hold the primary evidence: mtime-keyed `unlink()`, no trash, the `deleted_<uuid>` tombstones
sitting on disk, the Desktop update wipe, the 6.3 GB corpus measurements, the compression numbers.
"Anatomy of how Claude Code deletes your work" carries the feature as its closing CTA, not its
headline. Sequence: ship week 1, publish week 2, return to Session Bench.

## 9. Testing

- Round-trip integrity: archive → restore → byte-compare against original; manifest per-entry
  sha256 is the oracle.
- Restored session resumes successfully via the existing resume path.
- Rescue triggers at the correct mtime boundary across representative `effectivePeriod` values,
  including short periods that exercise the margin clamp.
- Effective-period resolution picks the **minimum** across settings sources.
- Mid-copy deletion: upstream removed between manifest build and copy → clean skip, no partial
  archive committed, no crash.
- Desktop tombstone files excluded.
- Desktop directory session with workspace artifacts archives and restores whole.
- Launch sweep runs before other indexing work and completes on a cold 2,363-session corpus
  without blocking the UI.

## 10. Success criteria

1. A Claude CLI session that the user never starred survives its 30-day purge and remains
   resumable from Agent Sessions.
2. No Agent Sessions code path deletes user data.
3. Zero manual steps in the common case.
4. Archive size is visible in Preferences, so unbounded growth (§5.2) is observable by the user
   before it becomes a support complaint.

**Not a success criterion:** reduced disk usage. v1 increases it. See §5.2.
