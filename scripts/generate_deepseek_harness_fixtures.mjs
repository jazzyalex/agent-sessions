#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SOURCE_COMMIT = 'ddefc45fbc7f8e46dd73185e68295696d1297887'
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const REFERENCE_ROOT = resolve(SCRIPT_DIR, '..', '..', 'deepseek-harness')
const CATALOG_PATH = `${REFERENCE_ROOT}/packages/session/session-format-catalog/lib/index.js`
const ZSTD_PATH = `${REFERENCE_ROOT}/packages/session/session-persistence-jsonl/lib/types/zstd.js`
const DEFAULT_OUTPUT = 'AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness'
const GENERATOR_COMMAND = 'node scripts/generate_deepseek_harness_fixtures.mjs --output AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness'
const CREATED_AT = 1_700_000_000_000
const SYNTHETIC_CWD = '/tmp/synthetic-dsh-demo'

function outputPath() {
  const index = process.argv.indexOf('--output')
  if (index === -1) return resolve(DEFAULT_OUTPUT)
  const value = process.argv[index + 1]
  if (value === undefined || value.startsWith('--')) {
    throw new Error('--output requires a directory')
  }
  return resolve(value)
}

function verifyReferenceCommit() {
  const actual = execFileSync('git', ['-C', REFERENCE_ROOT, 'rev-parse', 'HEAD'], {
    encoding: 'utf8',
  }).trim()
  if (actual !== SOURCE_COMMIT) {
    throw new Error(`pinned DSH checkout mismatch: expected ${SOURCE_COMMIT}, got ${actual}`)
  }
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function sha256(text) {
  return createHash('sha256').update(text).digest('hex')
}

function event(type, seq, time, data, extras = {}) {
  return { type, seq, time, data, ...extras }
}

function userMessage(id, seq, time) {
  return event(
    'user/message',
    seq,
    time,
    {
      id,
      role: 'user',
      content: [{ type: 'text', text: 'SYNTHETIC fixture direct user message' }],
      source: { kind: 'user' },
    },
    { surfaceOp: 'append' },
  )
}

function assistantMessage(id, seq, time, sourceEventSeqs) {
  return event(
    'assistant/message',
    seq,
    time,
    {
      turn: 1,
      step: 1,
      message: {
        id,
        role: 'assistant',
        content: [{ type: 'text', text: 'SYNTHETIC fixture assistant reply' }],
        source: { kind: 'model', provider: 'synthetic-provider', model: 'synthetic-model' },
      },
      ...(sourceEventSeqs === undefined ? { stream: [] } : {}),
    },
    {
      ...(sourceEventSeqs === undefined ? {} : { sourceEventSeqs }),
      surfaceOp: 'append',
    },
  )
}

function packedTextRun(seq0) {
  return {
    type: 'text-chunks',
    seq0,
    time0: CREATED_AT + 3,
    data: {
      turn: 1,
      step: 1,
      index: 0,
      dt: [],
      texts: ['SYNTHETIC packed assistant text'],
    },
  }
}

function packedReasoningRun(seq0) {
  return {
    type: 'reasoning-chunks',
    seq0,
    time0: CREATED_AT + 4,
    data: {
      turn: 1,
      step: 1,
      index: 0,
      dt: [],
      texts: ['SYNTHETIC packed reasoning text'],
    },
  }
}

function historicalHeader(version, id) {
  return {
    type: 'session',
    version,
    id,
    createdAt: CREATED_AT,
    cwd: SYNTHETIC_CWD,
    delegationDepth: 0,
  }
}

function historicalRows(id, includeReasoning) {
  const packed = [packedTextRun(2)]
  if (includeReasoning) packed.push(packedReasoningRun(3))
  const assistantSeq = includeReasoning ? 4 : 3
  const closeSeq = includeReasoning ? 5 : 4
  return [
    event('turn/start', 0, CREATED_AT + 1, { turn: 1 }),
    event('step/start', 1, CREATED_AT + 2, { turn: 1, step: 1 }),
    ...packed,
    assistantMessage(`assistant-${id}`, assistantSeq, CREATED_AT + (includeReasoning ? 5 : 4), includeReasoning ? [2, 3] : [2]),
    event('step/end', closeSeq, CREATED_AT + (includeReasoning ? 6 : 5), { turn: 1, step: 1 }),
    event('turn/end', closeSeq + 1, CREATED_AT + (includeReasoning ? 7 : 6), { turn: 1, reason: { kind: 'completed' } }),
  ]
}

function v2Source(id) {
  return {
    header: {
      type: 'session',
      version: 2,
      id,
      createdAt: CREATED_AT,
      cwd: SYNTHETIC_CWD,
      isSeeded: false,
      delegationDepth: 0,
      agentPreset: 'code',
    },
    rows: [
      event('turn/start', 0, CREATED_AT + 1, { turn: 1 }),
      event('step/start', 1, CREATED_AT + 2, { turn: 1, step: 1 }),
      userMessage(`user-${id}`, 2, CREATED_AT + 3),
      event('request/header', 3, CREATED_AT + 4, {
        header: {
          config: { provider: 'synthetic-provider', model: 'synthetic-model' },
          system: 'SYNTHETIC system context',
        },
        reason: 'initial',
      }),
      event('tool/code-dispatch-start', 4, CREATED_AT + 5, {
        rootCallId: 'call-synth-root',
        parentCallId: 'call-synth-root',
        subCallId: 'call-synth-sub',
        name: 'read',
        arguments: { path: 'SYNTHETIC' },
      }),
      event('tool/code-dispatch', 5, CREATED_AT + 6, {
        rootCallId: 'call-synth-root',
        parentCallId: 'call-synth-root',
        subCallId: 'call-synth-sub',
        name: 'read',
        arguments: { path: 'SYNTHETIC' },
        isError: false,
        content: [{ type: 'text', text: 'SYNTHETIC tool output' }],
      }),
      assistantMessage(`assistant-${id}`, 6, CREATED_AT + 7),
      event('step/end', 7, CREATED_AT + 8, { turn: 1, step: 1 }),
      event('turn/end', 8, CREATED_AT + 9, { turn: 1, reason: { kind: 'completed' } }),
    ],
  }
}

function restore(header, rows) {
  const current = sessionFormatCatalog.createRestore(header, {
    recovery: 'strict',
    validation: 'current',
  })
  for (const row of rows) current.decodeRow(row)
  return current.finish()
}

function physicalText(header, rows) {
  return `${[header, ...rows].map(row => JSON.stringify(row)).join('\n')}\n`
}

function encodedV3(source) {
  const artifact = restore(source.header, source.rows)
  const header = sessionFormatCatalog.encodeCurrentHeader(artifact.header, artifact.inheritedEventCount)
  const rows = artifact.events.map(eventValue => sessionFormatCatalog.encodeCurrentEvent(eventValue))
  return { artifact, header, rows }
}

function withUnknown(base, ignorable) {
  const rows = [...base.rows]
  const last = rows.at(-1)
  rows.push({
    type: ignorable ? 'x-synth/unknown-ignorable' : 'x-synth/unknown-required',
    seq: last.seq + 1,
    time: last.time + 1,
    data: { detail: 'SYNTHETIC unknown extension payload' },
    ...(ignorable ? { ignorable: true } : {}),
  })
  return rows
}

function tornTail(text) {
  const lines = text.trimEnd().split('\n')
  const final = lines.pop()
  if (final === undefined || final.length < 16) throw new Error('v3 fixture final row is unexpectedly short')
  lines.push(final.slice(0, -12))
  return lines.join('\n')
}

function sequenceGap(rows) {
  return rows.map((row, index) => index === 3 ? { ...row, seq: row.seq + 1 } : row)
}

function assertSanitized(label, text) {
  const forbidden = [
    /\/(?:Users|home)\//,
    /(?:^|[\\/])\.env(?:$|[.\\/])/i,
    /bearer\s+[a-z0-9._-]+/i,
    /(?:password|credential|secret|api[_-]?key)\s*[:=]/i,
  ]
  for (const pattern of forbidden) {
    if (pattern.test(text)) throw new Error(`${label} contains forbidden sensitive-looking content: ${pattern}`)
  }
}

function writeFile(output, name, text) {
  assertSanitized(name, text)
  writeFileSync(resolve(output, name), text, 'utf8')
  return text
}

function writeBinaryFile(output, name, data) {
  writeFileSync(resolve(output, name), data)
  return data
}

verifyReferenceCommit()
const { sessionFormatCatalog } = await import(CATALOG_PATH)
const { compressZstdFrame } = await import(ZSTD_PATH)
const output = outputPath()
mkdirSync(dirname(resolve(output, 'manifest.json')), { recursive: true })
mkdirSync(output, { recursive: true })

const sources = new Map()
for (const version of [0, 1]) {
  const id = `dsh-synth-v${version}-0001`
  const header = historicalHeader(version, id)
  const rows = historicalRows(id, version === 1)
  sources.set(`v${version}_minimal_session.jsonl`, { header, rows, artifact: restore(header, rows) })
}

const v2 = v2Source('dsh-synth-v2-0001')
const v2Artifact = restore(v2.header, v2.rows)
sources.set('v2_minimal_session.jsonl', { header: v2.header, rows: v2.rows, artifact: v2Artifact })

const v3SourceValue = v2Source('dsh-synth-v3-0001')
const v3 = encodedV3(v3SourceValue)
sources.set('v3_minimal_session.jsonl', { header: v3.header, rows: v3.rows, artifact: restore(v3.header, v3.rows) })
const unknownIgnorableRows = withUnknown(v3, true)
sources.set('unknown_ignorable_event.jsonl', {
  header: v3.header,
  rows: unknownIgnorableRows,
  artifact: restore(v3.header, unknownIgnorableRows),
})
const unknownRequiredRows = withUnknown(v3, false)
try {
  restore(v3.header, unknownRequiredRows)
  throw new Error('unknown required fixture unexpectedly passed the pinned v3 catalog')
} catch (error) {
  if (error instanceof Error && error.message.startsWith('unknown required fixture unexpectedly')) throw error
}

const v3Text = physicalText(v3.header, v3.rows)
const physicalFixtures = new Map([
  ['v0_minimal_session.jsonl', physicalText(sources.get('v0_minimal_session.jsonl').header, sources.get('v0_minimal_session.jsonl').rows)],
  ['v1_minimal_session.jsonl', physicalText(sources.get('v1_minimal_session.jsonl').header, sources.get('v1_minimal_session.jsonl').rows)],
  ['v2_minimal_session.jsonl', physicalText(v2.header, v2.rows)],
  ['v3_minimal_session.jsonl', v3Text],
  ['malformed_torn_tail.jsonl', tornTail(v3Text)],
  ['malformed_seq_gap.jsonl', physicalText(v3.header, sequenceGap(v3.rows))],
  ['future_v4_header.jsonl', physicalText({ ...v3.header, version: 4 }, v3.rows)],
  ['unknown_ignorable_event.jsonl', physicalText(v3.header, unknownIgnorableRows)],
  ['unknown_required_event.jsonl', physicalText(v3.header, unknownRequiredRows)],
])

const expected = {
  sourceCommit: SOURCE_COMMIT,
  generatedBy: GENERATOR_COMMAND,
  catalog: '@deepseek-ai/dsh-session-format-catalog/sessionFormatCatalog',
  fixtures: {},
}
for (const [name, fixture] of sources) {
  expected.fixtures[name] = fixture.artifact
}
const expectedText = `${stableJSON(expected)}\n`
writeFile(output, 'normalized_v3_expected.json', expectedText)

for (const [name, text] of physicalFixtures) writeFile(output, name, text)

const compressedSourceNames = [
  'v0_minimal_session.jsonl',
  'v1_minimal_session.jsonl',
  'v2_minimal_session.jsonl',
  'v3_minimal_session.jsonl',
  'unknown_ignorable_event.jsonl',
]
const compressedFixtures = new Map()
for (const name of compressedSourceNames) {
  const text = physicalFixtures.get(name)
  if (text === undefined) throw new Error(`missing accepted plain fixture for compression: ${name}`)
  const lines = text.split('\n')
  if (lines.at(-1) === '') lines.pop()
  if (lines.some(line => line.length === 0)) throw new Error(`accepted fixture contains an empty JSONL record: ${name}`)
  const frames = await Promise.all(lines.map(line => compressZstdFrame(`${line}\n`)))
  const compressed = Buffer.concat(frames)
  const compressedName = name.replace(/\.jsonl$/, '.jsonl.zstd')
  compressedFixtures.set(compressedName, writeBinaryFile(output, compressedName, compressed))
}

const expectedHash = sha256(expectedText)
const fixtureMetadata = [
  ['v0_minimal_session.jsonl', 0, 'accept: normalize v0->v1->v2->v3; fold the released packed text run exactly once into the assistant stream', 'Generated from the released v0 physical header and packed text-chunks row shapes, then validated and normalized by the pinned production catalog.'],
  ['v1_minimal_session.jsonl', 1, 'accept: normalize v1->v2->v3; fold the released packed text and reasoning runs exactly once into the assistant stream', 'Generated from the released v1 shared-layout header and packed text-chunks/reasoning-chunks row shapes, then validated and normalized by the pinned production catalog.'],
  ['v2_minimal_session.jsonl', 2, 'accept: normalize v2->v3; insert and protect the system head, map agentPreset code to ptc, and rename code dispatch events to PTC', 'Generated from the released v2 one-event-per-row schema, including a complete synthetic code-dispatch lifecycle, then validated through the pinned v2-to-v3 migration and current catalog.'],
  ['v3_minimal_session.jsonl', 3, 'accept: native v3 zero-based dense events with canonical surface metadata and system head', 'Encoded from the pinned catalog-produced v3 artifact with the production current encoder; no historical fields were hand-schematized.'],
  ['malformed_torn_tail.jsonl', 3, 'reject: final JSONL record is truncated before its closing bytes', 'Derived byte-for-byte from the generated v3 fixture by truncating the final JSON object by 12 UTF-8 bytes and removing its final line terminator.'],
  ['malformed_seq_gap.jsonl', 3, 'reject: dense physical sequence fails at the user/message row', 'Derived from the generated v3 fixture by changing only the user/message seq from 3 to 4, leaving later rows unchanged.'],
  ['future_v4_header.jsonl', 4, 'reject: header version is newer than the supported v3 catalog', 'Derived from the generated v3 fixture by changing only the physical header version from 3 to 4.'],
  ['unknown_ignorable_event.jsonl', 3, 'accept: retain the source event for diagnostics while treating the unknown ignorable event as non-rendered', 'Derived from the generated v3 fixture by appending one dense x-synth/unknown-ignorable event with ignorable true.'],
  ['unknown_required_event.jsonl', 3, 'reject: unknown required event is refused by the released v3 admission rules', 'Derived from the generated v3 fixture by appending one dense x-synth/unknown-required event with ignorable false.'],
]
const fixtures = fixtureMetadata.map(([name, version, outcome, note]) => ({
  file: name,
  physicalFormatVersion: version,
  physicalFormat: version < 2
    ? `released v${version} plain JSONL header plus zero-based envelopes and released packed assistant rows`
    : `released v${version} plain JSONL header plus zero-based one-event-per-row envelopes`,
  generation: 0,
  encoding: 'plain-jsonl',
  expectedOutcome: outcome,
  derivationNote: note,
  generatorCommand: GENERATOR_COMMAND,
  ...(name in expected.fixtures ? { expectedNormalizedV3: 'normalized_v3_expected.json' } : {}),
  sha256: sha256(physicalFixtures.get(name)),
}))
const fixtureMetadataByName = new Map(fixtureMetadata.map(metadata => [metadata[0], metadata]))
for (const name of compressedSourceNames) {
  const [, version, outcome, note] = fixtureMetadataByName.get(name)
  const compressedName = name.replace(/\.jsonl$/, '.jsonl.zstd')
  fixtures.push({
    file: compressedName,
    physicalFormatVersion: version,
    physicalFormat: `${version < 2
      ? `released v${version} plain JSONL header plus zero-based envelopes and released packed assistant rows`
      : `released v${version} plain JSONL header plus zero-based one-event-per-row envelopes`}; each record is one independently framed Zstandard payload`,
    generation: 0,
    encoding: 'zstd-jsonl',
    expectedOutcome: outcome,
    derivationNote: `Derived from ${name}: frame the header line alone as frame 0 and every later JSONL record in its own independently compressed, checksummed Zstandard frame using the pinned ${SOURCE_COMMIT} reference implementation's built compressZstdFrame. ${note}`,
    generatorCommand: GENERATOR_COMMAND,
    expectedNormalizedV3: 'normalized_v3_expected.json',
    sha256: sha256(compressedFixtures.get(compressedName)),
  })
}
const manifest = {
  sourceCommit: SOURCE_COMMIT,
  generatorCommand: GENERATOR_COMMAND,
  generator: 'scripts/generate_deepseek_harness_fixtures.mjs',
  physicalFormat: 'UTF-8 plain JSONL with LF line endings plus independently framed Zstandard variants; v0/v1 use released packed assistant rows; v2/v3 use one event envelope per row; all physical sequences are zero-based and dense for accepted fixtures.',
  encoding: 'plain-jsonl or zstd-jsonl: plain fixtures are UTF-8 LF-delimited records; compressed fixtures frame the header line alone first and every later JSONL record independently with checksummed Zstandard.',
  generation: 'Each fixture is a generation-0 session artifact; physicalFormatVersion identifies its released DSH schema.',
  expectedNormalizedV3: {
    file: 'normalized_v3_expected.json',
    physicalFormat: 'canonical stable-key JSON map of catalog-restored v3 artifacts',
    generation: 3,
    encoding: 'utf-8-json',
    expectedOutcome: 'accepted v0-v3 fixtures normalize to the recorded v3 artifact; malformed fixtures intentionally have no normalized output.',
    derivationNote: 'Produced by the pinned @deepseek-ai/dsh-session-format-catalog sessionFormatCatalog using strict current validation, then serialized with recursively sorted JSON object keys.',
    generatorCommand: GENERATOR_COMMAND,
    sha256: expectedHash,
  },
  fixtures,
  syntheticDataStatement: 'All content is synthetic: fixed timestamps, /tmp/synthetic-dsh-demo, dsh-synth identifiers, and SYNTHETIC-marked text. No real prompts, cwd paths, usernames, credentials, tokens, environment files, or attachments were used.',
}
writeFile(output, 'manifest.json', `${stableJSON(manifest)}\n`)

console.log(`generated ${physicalFixtures.size} JSONL fixtures, ${compressedFixtures.size} Zstandard fixtures, and normalized_v3_expected.json in ${output}`)
