#!/usr/bin/env node

// Synthetic native v4 fixture for the DSH 0.2.1-rc.2 shapes seen in two real
// sessions (key names only): turn 1 runs one shell tool, which 0.2.1-rc.2
// records with the new required job/registered and job/settled events; turn 2
// fails before any assistant message (a failed assistant/attempt and a
// structured turn/end error). The title request carries the new optional
// reasoningEffort. Every scalar value is synthetic. The installed production
// catalog must admit the rows with strict current validation before anything
// is written.

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const DSH_VERSION = '0.2.1-rc.2'
const DSH_SOURCE_COMMIT = '687f282e8625c6b8d11ff58211a90524be2e4317'
const DSH_SOURCE_TAG = 'dsh-v0.2.1-rc.2'
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
  const id = 'dsh-synth-v4-job-session-0001'
  const failure = {
    message: 'SYNTHETIC provider route has no credential',
    code: 'MISSING_CREDENTIAL',
  }
  const prompt = {
    content: [{ type: 'text', text: 'SYNTHETIC request' }],
    source: { kind: 'user' },
    role: 'user',
    id: 'user-v4j-1',
  }
  const followUp = {
    content: [{ type: 'text', text: 'SYNTHETIC follow-up' }],
    source: { kind: 'user' },
    role: 'user',
    id: 'user-v4j-2',
  }
  const route = { provider: 'synthetic-provider', model: 'synthetic-model' }
  const usage = {
    inputTokens: 10,
    outputTokens: 5,
    cacheReadTokens: 2,
    cacheWriteTokens: 1,
    totalTokens: 18,
  }
  const toolArguments = '{"command":"SYNTHETIC"}'
  const job = {
    jobId: 'job-v4j-1',
    owner: id,
    kind: 'bash',
    label: 'SYNTHETIC',
    startedAt: CREATED_AT + 16,
    toolCall: { callId: 'call-v4j-1', rootCallId: 'call-v4j-1' },
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
    event('permission/preset', 0, { preset: 'workspace-write' }),
    event('sandbox/mode', 1, { mode: 'workspace-write' }),
    event('approval/policy', 2, { policy: 'ask' }),
    event('agent/inbox/spliced', 3, { target: 'next-turn', start: 0, inserted: [prompt] }),
    event('turn/start', 4, { turn: 1 }),
    event('agent/inbox/spliced', 5, { target: 'next-turn', start: 0, removedCount: 1, inserted: [] }),
    event('step/start', 6, { turn: 1, step: 1 }),
    event('system/message', 7, {
      turn: 1,
      step: 1,
      message: {
        role: 'system',
        content: [{ type: 'text', text: 'SYNTHETIC system context' }],
        source: { kind: 'system-prompt' },
        id: 'system-v4j-1',
      },
    }, { surfaceOp: 'append' }),
    event('user/message', 8, prompt, { surfaceOp: 'append' }),
    event('request/header', 9, {
      header: {
        config: { ...route, maxTokens: 1024, reasoningEffort: 'high' },
        adapterDefaults: { reasoningEffort: true, maxTokens: true },
        tools: [{
          name: 'synthetic_shell',
          description: 'SYNTHETIC tool',
          parameters: {
            type: 'object',
            properties: { command: { type: 'string' } },
            required: ['command'],
          },
        }],
      },
      reason: 'initial',
    }),
    event('request/context', 10, {
      ...route,
      contextWindow: 4096,
      systemPromptUpdate: 'in-history',
    }),
    event('session/title', 11, {
      title: 'SYNTHETIC request',
      messageSeqs: [8],
      source: { kind: 'fallback' },
    }),
    event('session/title-llm-request', 12, {
      titleProvider: 'session-title-first-prompt-llm',
      messageSeqs: [8],
      route,
      system: 'SYNTHETIC title instructions',
      messages: [{
        content: [{ type: 'text', text: 'SYNTHETIC title input' }],
        source: { kind: 'dsh-session-title-llm' },
        role: 'user',
        id: 'title-v4j-1',
      }],
      maxTokens: 64,
      reasoningEffort: 'off',
    }),
    event('session-log-deepseek/delivery-accepted', 13, {
      sessionId: id,
      sessionFormatVersion: 4,
      throughSeq: 12,
    }),
    event('assistant/message', 14, {
      turn: 1,
      step: 1,
      message: {
        role: 'assistant',
        content: [{
          type: 'tool-call',
          id: 'call-v4j-1',
          name: 'synthetic_shell',
          arguments: toolArguments,
        }],
        source: { kind: 'model', ...route },
        id: 'assistant-v4j-1',
      },
      usage,
      stream: [],
    }, { surfaceOp: 'append' }),
    event('tool/call', 15, {
      turn: 1,
      step: 1,
      callId: 'call-v4j-1',
      name: 'synthetic_shell',
      arguments: toolArguments,
    }),
    event('job/registered', 16, job),
    event('job/settled', 17, {
      ...job,
      finishedAt: CREATED_AT + 17,
      status: 'completed',
      cause: 'producer',
      producerReported: true,
      detail: 'exit code: 0',
    }),
    event('tool/result', 18, {
      turn: 1,
      step: 1,
      message: {
        role: 'tool',
        source: { kind: 'tool', callId: 'call-v4j-1' },
        toolCallId: 'call-v4j-1',
        content: [{ type: 'text', text: 'SYNTHETIC tool output' }],
        isError: false,
        id: 'tool-result-v4j-1',
      },
    }, { surfaceOp: 'append', sourceEventSeqs: [15] }),
    event('step/end', 19, { turn: 1, step: 1 }),
    event('step/start', 20, { turn: 1, step: 2 }),
    event('assistant/message', 21, {
      turn: 1,
      step: 2,
      message: {
        role: 'assistant',
        content: [{ type: 'text', text: 'SYNTHETIC final response' }],
        source: { kind: 'model', ...route },
        id: 'assistant-v4j-2',
      },
      usage,
      stream: [],
    }, { surfaceOp: 'append' }),
    event('step/end', 22, { turn: 1, step: 2 }),
    event('turn/end', 23, { turn: 1, reason: { kind: 'completed' } }),
    event('agent/inbox/spliced', 24, { target: 'next-turn', start: 0, inserted: [followUp] }),
    event('turn/start', 25, { turn: 2 }),
    event('agent/inbox/spliced', 26, { target: 'next-turn', start: 0, removedCount: 1, inserted: [] }),
    event('step/start', 27, { turn: 2, step: 1 }),
    event('user/message', 28, followUp, { surfaceOp: 'append' }),
    event('assistant/attempt', 29, {
      turn: 2,
      step: 1,
      stream: [{
        type: 'chunk',
        time: CREATED_AT + 29,
        chunk: { type: 'finish', reason: { kind: 'error', failure } },
      }],
    }),
    event('step/end', 30, { turn: 2, step: 1 }),
    event('turn/end', 31, { turn: 2, reason: { kind: 'error', error: failure } }),
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
const plainName = 'v4_job_failed_turn_session.jsonl'
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
