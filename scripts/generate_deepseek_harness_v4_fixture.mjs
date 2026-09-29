#!/usr/bin/env node

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const DSH_VERSION = '0.2.0-rc.2'
const DSH_SOURCE_COMMIT = '639ed015397290b3745d163aafe02ffee4aa3f84'
const DSH_SOURCE_TAG = 'dsh-v0.2.0-rc.2'
const DEFAULT_OUTPUT = 'AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness'
const CREATED_AT = 1_700_000_000_000

function outputPath() {
  const index = process.argv.indexOf('--output')
  if (index === -1) return resolve(DEFAULT_OUTPUT)
  const value = process.argv[index + 1]
  if (value === undefined || value.startsWith('--')) throw new Error('--output requires a directory')
  return resolve(value)
}

function event(type, seq, data, extras = {}) {
  return { type, seq, time: CREATED_AT + seq, data, ...extras }
}

function fixture() {
  const id = 'dsh-synth-v4-tool-0001'
  const usage = {
    inputTokens: 10,
    outputTokens: 5,
    cacheReadTokens: 2,
    cacheWriteTokens: 1,
    totalTokens: 18,
  }
  const header = {
    type: 'session',
    version: 4,
    id,
    createdAt: CREATED_AT,
    cwd: '/tmp/synthetic-dsh-demo',
    isSeeded: false,
    delegationDepth: 0,
  }
  const rows = [
    event('turn/start', 0, { turn: 1 }),
    event('step/start', 1, { turn: 1, step: 1 }),
    event('system/message', 2, {
      turn: 1,
      step: 1,
      message: {
        id: 'system-v4-1',
        role: 'system',
        content: [{ type: 'text', text: 'SYNTHETIC system context' }],
        source: { kind: 'system-prompt' },
      },
    }, { surfaceOp: 'append' }),
    event('user/message', 3, {
      id: 'user-v4-1',
      role: 'user',
      content: [{ type: 'text', text: 'SYNTHETIC request' }],
      source: { kind: 'user' },
    }, { surfaceOp: 'append' }),
    event('request/header', 4, {
      header: {
        config: { provider: 'synthetic-provider', model: 'synthetic-model' },
        tools: [{
          name: 'synthetic_tool',
          description: 'SYNTHETIC tool',
          parameters: {
            type: 'object',
            properties: { value: { type: 'string' } },
            required: ['value'],
          },
        }],
      },
      reason: 'initial',
    }),
    event('session-log-deepseek/delivery-accepted', 5, {
      sessionId: id,
      sessionFormatVersion: 4,
      throughSeq: 4,
    }),
    event('assistant/message', 6, {
      turn: 1,
      step: 1,
      message: {
        id: 'assistant-v4-1',
        role: 'assistant',
        content: [
          { type: 'text', text: 'SYNTHETIC tool preface' },
          {
            type: 'tool-call',
            id: 'call-v4-1',
            name: 'synthetic_tool',
            arguments: '{"value":"SYNTHETIC"}',
          },
        ],
        source: { kind: 'model', provider: 'synthetic-provider', model: 'synthetic-model' },
      },
      usage,
      stream: [],
    }, { surfaceOp: 'append' }),
    event('tool/call', 7, {
      turn: 1,
      step: 1,
      callId: 'call-v4-1',
      name: 'synthetic_tool',
      arguments: '{"value":"SYNTHETIC"}',
    }),
    event('tool/result', 8, {
      turn: 1,
      step: 1,
      message: {
        id: 'tool-result-v4-1',
        role: 'tool',
        source: { kind: 'tool', callId: 'call-v4-1' },
        toolCallId: 'call-v4-1',
        content: [{ type: 'text', text: 'SYNTHETIC tool output' }],
        isError: false,
      },
    }, { surfaceOp: 'append', sourceEventSeqs: [6] }),
    event('step/end', 9, { turn: 1, step: 1 }),
    event('step/start', 10, { turn: 1, step: 2 }),
    event('assistant/message', 11, {
      turn: 1,
      step: 2,
      message: {
        id: 'assistant-v4-2',
        role: 'assistant',
        content: [{ type: 'text', text: 'SYNTHETIC final response' }],
        source: { kind: 'model', provider: 'synthetic-provider', model: 'synthetic-model' },
      },
      usage,
      stream: [],
    }, { surfaceOp: 'append' }),
    event('step/end', 12, { turn: 1, step: 2 }),
    event('turn/end', 13, { turn: 1, reason: { kind: 'completed' } }),
  ]
  return { header, rows }
}

function compressFrames(text) {
  const frames = []
  for (const line of text.trimEnd().split('\n')) {
    const compressed = spawnSync('zstd', ['-q', '--stdout', '--check'], {
      input: Buffer.from(`${line}\n`, 'utf8'),
      maxBuffer: 16 * 1024 * 1024,
    })
    if (compressed.status !== 0) {
      throw new Error(`zstd failed: ${compressed.stderr.toString('utf8')}`)
    }
    frames.push(compressed.stdout)
  }
  return Buffer.concat(frames)
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex')
}

const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
const dshRoot = resolve(globalRoot, '@deepseek-ai/dsh')
const packageJSON = JSON.parse(readFileSync(resolve(dshRoot, 'package.json'), 'utf8'))
if (packageJSON.version !== DSH_VERSION) {
  throw new Error(`expected @deepseek-ai/dsh ${DSH_VERSION}, got ${packageJSON.version}`)
}
const catalogPath = resolve(
  dshRoot,
  'node_modules/@deepseek-ai/dsh-session-format-catalog/lib/index.js',
)
const { sessionFormatCatalog } = await import(pathToFileURL(catalogPath).href)
if (sessionFormatCatalog.currentVersion !== 4) {
  throw new Error(`expected current DSH catalog v4, got v${sessionFormatCatalog.currentVersion}`)
}

const { header, rows } = fixture()
const restore = sessionFormatCatalog.createRestore(header, {
  recovery: 'strict',
  validation: 'current',
})
for (const row of rows) restore.decodeRow(row)
const artifact = restore.finish()
if (artifact.header.version !== 4 || artifact.events.length !== rows.length) {
  throw new Error('authoritative DSH catalog changed the synthetic v4 fixture unexpectedly')
}

const text = `${[header, ...rows].map(value => JSON.stringify(value)).join('\n')}\n`
const compressed = compressFrames(text)
const output = outputPath()
mkdirSync(output, { recursive: true })
const plainName = 'v4_tool_session.jsonl'
const compressedName = `${plainName}.zstd`
writeFileSync(resolve(output, plainName), text, 'utf8')
writeFileSync(resolve(output, compressedName), compressed)

console.log(JSON.stringify({
  dshVersion: DSH_VERSION,
  sourceCommit: DSH_SOURCE_COMMIT,
  sourceTag: DSH_SOURCE_TAG,
  catalogVersion: sessionFormatCatalog.currentVersion,
  events: rows.length,
  files: {
    [plainName]: sha256(text),
    [compressedName]: sha256(compressed),
  },
}))
