# DeepSeek Harness session source — preparation

Status: **preparation only.** No Swift written, no `SessionSource` case, no pbxproj edit.
Target release: **5.2** (`versionIntroduced = "5.2"`), i.e. the release after 5.1
(Devin + fx). Owner decision 2026-08-30.

Everything below is verified against `dsh-v0.1.2-alpha.2` unless a line says otherwise.
DSH ships every few days, so **re-verify before implementing** (see §7).

---

## 1. Why this source is worth the work

`deepseek-ai/deepseek-harness` launched 2026-08-13 and passed **191,500 stars in 17 days**
— the largest coding-agent audience in existence, and no session browser supports it yet.
Outreach thread: https://github.com/deepseek-ai/deepseek-harness/discussions/4425

## 2. On-disk layout

```
~/.dsh/sessions/                      # dshHomePath('sessions'); DSH_HOME → ~/.dsh
  --<normalized-cwd>--/               # projectKey(cwd), lossy: separators → '-', truncated
    <encodeSegment(sessionId)>/       # '~' → '~007E', no traversal, no collision
      session.jsonl.zstd              # default
      session.jsonl                   # only when compression: 'none'
```

- **One encoding per root.** An opposite suffix in the same root is a hard error upstream,
  not a fallback. Discovery must not mix them.
- Legacy flat `<project>/<id>.jsonl*` artifacts are **rejected** by DSH, not ignored.
- The cwd grouping is lossy: different cwds can share a project directory. The **session id
  selects the session**, never the directory name.
- ⚠️ Installs predating 2026-07-28 may have a *relative* `./.sessions` root per launch
  directory (the TUI's old default). Worth probing for; do not assume `~/.dsh/sessions` is
  the only place sessions exist.

## 3. Logical format

First logical line is the out-of-log header, in **its own zstd frame** so listing is
metadata-only:

```json
{"type":"session","version":0,"id":"…","createdAt":1700000000000,
 "cwd":"/path","delegationDepth":0,"agentPreset":"standard"}
```

`parentSession` / `seedLength` / `origin` appear on sub-agent and seeded sessions
(`delegationDepth > 0`). `createdAt` is integer Unix ms.

Every later line is either a verbatim `SessionEvent {type, seq, time, data}` or a **packed
chunk row**. Packed row tags are bare and slash-less so they can't collide with event types:
`text-chunks`, `reasoning-chunks`, `tool-call-chunks`. Verified example:

```json
{"type":"text-chunks","seq0":3,"time0":1700000000003,
 "data":{"turn":1,"step":1,"index":0,"dt":[1,1,1],"texts":["Hel","lo"," ","world."]}}
```

N items with N−1 `dt` gaps, expanding to N `assistant/chunk` events at `seq0 … seq0+N−1`.
The whole decoded log must satisfy **`events[i].seq === i`**.

## 4. Traps — each of these silently loses data

**4.1 One-shot zstd decompress returns only the header.** The artifact is a *concatenation
of independent frames*. Node's `zstdDecompressSync` **and** `createZstdDecompress` both stop
after frame 1. Measured on the healthy fixture: whole-buffer decode → **1 line**; correct
per-frame decode → **8 lines / 10 events**. A Swift reader calling a one-shot zstd API gets a
valid-looking session with zero events and no error. This is the single most dangerous trap
here — budget a test for it.

**4.2 `dt` and the item array live inside `data`,** not at the record's top level. A parser
reading `record.dt` finds nothing and silently emits one event where there were four.

**4.3 `sourceEventSeqs` range-encoding (new in 0.1.2-alpha.x).** Storage records gained a
provenance field encoded at the storage boundary: runs of ≥3 consecutive seqs collapse to
`[start, end]` pairs. Expand via `decodeSeqRanges(record.sourceEventSeqs, record.seq)`.
**`SESSION_FORMAT_VERSION` is still `0`**, so the header cannot signal this — a reader written
against rc.6/rc.8 mis-reads without any version mismatch to catch it.

**4.4 Frame splitting by magic bytes is a prep shortcut, not an implementation.** The scan in
§6 splits on `28 b5 2f fd`, which can occur inside compressed payload. A real reader parses
frame headers, block headers, payload sizes, and the checksum trailer, per DSH's own
`2026-07-19-zstandard-jsonl-session-logs.md`.

**4.5 A tolerant parser is required, not a strict one.** DSH's own loader rejects a whole file
over one bad record. Agent Sessions must not — a partly-readable session is still worth
showing. Accept unknown event types and unknown row tags rather than failing the session.

## 5. Capabilities for the descriptor

| Capability | Decision | Basis |
|---|---|---|
| Browse / search / filter | yes | format fully readable, proven in §6 |
| Analytics | yes | `assistant/message` carries provider + model |
| Resume | yes, `dsh --resume=<id>` | `apps/cli/README.md`; TUI chdirs to header `cwd` first |
| Archived history | none | DSH has no archive surface; all sessions live in one root |
| Image extraction | **out of scope for v1** | images are content-addressed *outside* the log in a separate attachment backend — matches the Qwen / Devin / fx precedent |

Resume caveat: a session whose header has **no `cwd`** cannot be resumed by DSH itself
("session has no recorded workspace"). Mark those ineligible rather than emitting a command
that will fail.

## 6. Proven reader (reference, Node — algorithm to port)

Verified against both MIT fixtures from `xiaoshenming/dsh-session-surgeon`:
`healthy-packed` → 10 events, seq 0..9, contiguous. `lone-surrogate` → 6 events, contiguous.

```js
import { zstdDecompressSync } from 'node:zlib'
import { readFileSync } from 'node:fs'
const MAGIC = Buffer.from([0x28,0xb5,0x2f,0xfd])
const PACKED = { 'text-chunks':'texts', 'reasoning-chunks':'reasonings', 'tool-call-chunks':'toolCalls' }

function frames(buf){ const s=[]
  for(let i=0;i+4<=buf.length;i++) if(buf.subarray(i,i+4).equals(MAGIC)) s.push(i)
  return s.map((o,i)=>buf.subarray(o, s[i+1] ?? buf.length)) }        // see trap 4.4

function readLog(file){ const buf=readFileSync(file); const out=[]
  frames(buf).forEach(fr=>{ try{ out.push(...zstdDecompressSync(fr).toString('utf8').split('\n').filter(Boolean)) }
    catch(e){ /* tolerate: keep prior frames, per trap 4.5 */ } })
  return out }

function expand(rec){ const key=PACKED[rec.type]; if(!key) return [rec]
  const d=rec.data, items=d[key]??[], dt=d.dt??[]                      // trap 4.2
  const evs=[]; let seq=rec.seq0, time=rec.time0
  items.forEach((item,i)=>{ if(i>0){ seq+=1; time+=dt[i-1] }
    evs.push({type:'assistant/chunk', seq, time, data:{...d,[key]:undefined,item}}) })
  return evs }
```

Fetch the fixtures (MIT, synthetic, contain nobody's real sessions):

```bash
gh api "repos/xiaoshenming/dsh-session-surgeon/contents/fixtures/synthetic/healthy-packed.session.jsonl.zstd" --jq '.content' | base64 -d > healthy-packed.session.jsonl.zstd
```

Also carries `lone-surrogate`, `orphan-tmp`, and a `build.mjs` generator for more.
**Attribution owed** in the fixture directory and release notes if these ship.
Note they are rc.6-era: none carries `sourceEventSeqs`, so they do **not** cover trap 4.3.

## 7. Before writing any Swift

1. **Re-verify the format against the then-current tag.** It moved once in six days with the
   version field pinned at `0`. Diff `packages/session/session-persistence-jsonl/src/format.ts`
   against `dsh-v0.1.2-alpha.2` and read the delta.
2. **Pin the parser to a recorded tag** and add a drift test, or this rots silently.
3. **Get a steward.** Synthetic fixtures prove the codec; they cannot prove discovery, real
   cwd shapes, sub-agent sessions, or resume. Outstanding ask in discussion #4425.

## 8. Obligations (from `docs/adding-a-session-source.md`)

Source folder `AgentSessions/DSH/` (Settings, CLIEnvironment, SourceDescriptor) ·
`Services/DSHSession{Parser,Discovery,Indexer}.swift` · `DSHResume/` ·
`Views/Preferences/PreferencesView+DSH.swift` · fixtures under
`Resources/Fixtures/stage0/agents/dsh/` · the `SessionSource` case and its four metadata arms ·
one line in `SessionSourceRegistry.ordered` · one `scripts/xcode_add_file.rb` run per new file ·
the §6 semantic switch arms · user-facing docs per §6.D · `versionIntroduced = "5.2"`.

Watch the K15 boundary: `SessionSource.swift`, `Session.swift`, `FilterEngine.swift` and the
parsers compile into `AgentSessionsLogicTests` and must not gain app-target dependencies.

## 9. Open questions for a steward

- Does a real `~/.dsh/sessions` match §2, including the `--<cwd>--` spelling?
- Do sub-agent sessions (`delegationDepth > 0`) appear as siblings, and should Agent Sessions
  nest them under the parent the way it nests Codex sub-agents?
- Does `dsh --resume=<id>` actually reopen from outside the TUI, and does it need `--profile tui`?
- Do real logs carry `sourceEventSeqs` yet, and in what shape?
