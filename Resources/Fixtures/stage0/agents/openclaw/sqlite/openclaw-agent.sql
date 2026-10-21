-- OpenClaw 2026.10.5 per-agent SQLite store (agents/<id>/agent/openclaw-agent.sqlite).
-- Schema copied verbatim from a real store (schema_meta schema_version 25) for the
-- tables Agent Sessions and agent_watch read. Every value is synthetic (redaction:
-- skills/agent-session-format-check/SKILL.md section 7). Row migrated-tool-1 is stored
-- zstd-compressed exactly as OpenClaw writes it (event_json NULL, event_zstd = one
-- level-1 frame with checksum, event_utf8_bytes = decoded size).
-- Built in-test with sqlite3_exec / sqlite3.executescript; do not hand-edit the blob.
CREATE TABLE "schema_meta" (
  meta_key TEXT NOT NULL PRIMARY KEY,
  role TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  agent_id TEXT,
  app_version TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;
CREATE TABLE session_windows (
  session_id TEXT NOT NULL PRIMARY KEY,
  session_key TEXT NOT NULL,
  previous_session_id TEXT,
  reason TEXT CHECK (reason IS NULL OR reason IN ('initial', 'reset', 'rollover', 'fork', 'rewind', 'switch', 'recovery', 'compaction')),
  session_scope TEXT NOT NULL DEFAULT 'conversation' CHECK (session_scope IN ('conversation', 'shared-main', 'group', 'channel')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  transcript_updated_at INTEGER DEFAULT NULL,
  transcript_observed_at INTEGER DEFAULT NULL,
  session_entry_provenance INTEGER NOT NULL DEFAULT 0 CHECK (session_entry_provenance IN (0, 1)),
  acp_owned INTEGER NOT NULL DEFAULT 0 CHECK (acp_owned IN (0, 1)),
  plugin_owner_id TEXT,
  hook_external_content_source TEXT CHECK (hook_external_content_source IS NULL OR hook_external_content_source IN ('gmail', 'webhook')),
  started_at INTEGER,
  ended_at INTEGER,
  status TEXT CHECK (status IS NULL OR status IN ('running', 'done', 'failed', 'killed', 'timeout')),
  chat_type TEXT CHECK (chat_type IS NULL OR chat_type IN ('direct', 'group', 'channel')),
  channel TEXT,
  account_id TEXT,
  primary_conversation_id TEXT,
  model_provider TEXT,
  model TEXT,
  agent_harness_id TEXT,
  parent_session_key TEXT,
  spawned_by TEXT,
  display_name TEXT
) STRICT;
CREATE TABLE "transcript_events" (
  session_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  event_json TEXT,
  created_at INTEGER NOT NULL,
  event_zstd BLOB,
  event_utf8_bytes INTEGER CHECK (event_utf8_bytes IS NULL OR event_utf8_bytes >= 0),
  navigation_json TEXT,
  PRIMARY KEY (session_id, seq),
  FOREIGN KEY (session_id) REFERENCES "session_windows"(session_id) ON DELETE CASCADE,
  CHECK (
    (event_json IS NOT NULL AND event_zstd IS NULL)
    OR (
      event_json IS NULL AND event_zstd IS NOT NULL
      AND event_utf8_bytes IS NOT NULL
      AND event_utf8_bytes BETWEEN 1 AND 4194304
      AND length(event_zstd) BETWEEN 1 AND 4194304
      AND navigation_json IS NOT NULL
    )
  )
) STRICT;
CREATE TABLE transcript_event_identities (
  session_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  event_type TEXT,
  parent_id TEXT,
  message_idempotency_key TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (session_id, event_id),
  FOREIGN KEY (session_id, seq) REFERENCES transcript_events(session_id, seq) ON DELETE CASCADE
) STRICT;
CREATE TABLE session_transcript_active_events (
  session_id TEXT NOT NULL,
  active_position INTEGER NOT NULL CHECK (active_position >= 0),
  event_seq INTEGER NOT NULL,
  message_position INTEGER CHECK (message_position IS NULL OR message_position >= 0),
  context_eligible INTEGER,
  PRIMARY KEY (session_id, active_position),
  FOREIGN KEY (session_id, event_seq) REFERENCES transcript_events(session_id, seq) ON DELETE CASCADE
) STRICT;
CREATE TABLE session_transcript_archives (
  session_id TEXT NOT NULL,
  generation TEXT NOT NULL,
  session_key TEXT NOT NULL,
  reason TEXT NOT NULL CHECK (reason IN ('deleted', 'reset')),
  encoding TEXT NOT NULL CHECK (encoding IN ('identity', 'zstd')),
  archive_blob BLOB NOT NULL,
  archive_sha256 TEXT NOT NULL CHECK (length(archive_sha256) = 64),
  archive_name TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  published_at INTEGER,
  publish_attempts INTEGER NOT NULL DEFAULT 0 CHECK (publish_attempts >= 0),
  last_publish_attempt_at INTEGER,
  last_publish_error TEXT,
  PRIMARY KEY (session_id, generation),
  CHECK (archive_name NOT LIKE '%/%' AND archive_name NOT LIKE '%\%')
) STRICT;
CREATE TABLE session_transcript_cold_archives (
  session_id TEXT NOT NULL PRIMARY KEY,
  generation TEXT NOT NULL,
  archive_name TEXT NOT NULL UNIQUE,
  archive_sha256 TEXT NOT NULL CHECK (length(archive_sha256) = 64),
  event_count INTEGER NOT NULL CHECK (event_count >= 1),
  raw_bytes INTEGER NOT NULL CHECK (raw_bytes >= 0),
  archive_bytes INTEGER NOT NULL CHECK (archive_bytes >= 0),
  last_seq INTEGER NOT NULL,
  archived_at INTEGER NOT NULL,
  storage TEXT NOT NULL CHECK (storage IN ('file', 'sqlite')),
  archive_blob BLOB,
  FOREIGN KEY (session_id) REFERENCES "session_windows"(session_id) ON DELETE CASCADE,
  CHECK (length(archive_name) > 0 AND archive_name NOT IN ('.', '..') AND archive_name NOT LIKE '%/%' AND archive_name NOT LIKE '%\%'),
  CHECK ((storage = 'file' AND archive_blob IS NULL) OR (storage = 'sqlite' AND archive_blob IS NOT NULL))
) STRICT;
INSERT INTO schema_meta VALUES ('primary', 'agent', 25, 'main', '2026.10.5', 1792486800000, 1792486800000);
INSERT INTO session_windows (session_id, session_key, created_at, updated_at, reason, started_at, ended_at, status, model, model_provider, agent_harness_id, display_name) VALUES ('openclaw-fixture-migrated', 'agent:main:recovered:openclaw-fixture-migrated', 1792486800000, 1792486804000, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-migrated', 1, '{"type":"session","version":3,"id":"openclaw-fixture-migrated","timestamp":"2026-10-20T09:00:00.000Z","cwd":"/tmp/repo"}', 1792486800000, NULL, 120, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-migrated', 'openclaw-fixture-migrated', 1, 'session', NULL, NULL, 1792486800000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-migrated', 0, 1, NULL, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-migrated', 2, '{"type":"message","id":"migrated-user-1","parentId":null,"timestamp":"2026-10-20T09:00:01.000Z","message":{"role":"user","content":"List the files in the fixture repo","timestamp":1792486801000,"idempotencyKey":"fixture-user-1","sourceChannel":"fixture-channel","__openclaw":{"mirrorIdentity":"fixture-mirror","mirrorOrigin":"fixture-origin","mirrorSourceFingerprint":"fixture-fingerprint","runId":"fixture-run-1","senderIsOwner":true,"upstreamUserText":"List the files in the fixture repo","transport":{"clients":[{"displayName":"fixture-client","id":"fixture-client-id","mode":"fixture"}]}}}}', 1792486801000, NULL, 594, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-migrated', 'migrated-user-1', 2, 'message', NULL, 'fixture-user-1', 1792486801000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-migrated', 1, 2, 0, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-migrated', 3, '{"type":"message","id":"migrated-assistant-1","parentId":"migrated-user-1","timestamp":"2026-10-20T09:00:02.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai","model":"fixture-model","stopReason":"toolUse","timestamp":1792486802000,"idempotencyKey":"fixture-assistant-1","content":[{"type":"text","text":"Listing the files."},{"type":"toolCall","id":"fixture-call-1","name":"bash","arguments":{"command":"ls"},"input":{"command":"ls"}}],"usage":{"input":120,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"reasoningTokens":4,"contextUsage":{"promptTokens":120,"state":"available","totalTokens":150}},"__openclaw":{"mirrorIdentity":"fixture-mirror","mirrorOrigin":"fixture-origin","mirrorSourceFingerprint":"fixture-fingerprint","runId":"fixture-run-1"}}}', 1792486802000, NULL, 865, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-migrated', 'migrated-assistant-1', 3, 'message', 'migrated-user-1', 'fixture-assistant-1', 1792486802000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-migrated', 2, 3, 1, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-migrated', 4, NULL, 1792486803000, X'28B52FFD649D0C7D1000D69A5125208D3807E0C9F1726F0BD5C48A90378A9BE84E062F6407081BC56BFB2B2F42950401046005420046004B00DC6F5FC8F293C6AEA0AA008D36D5C6500465145D948751E6EDD4E47AEEF4BAA3EBF9E6748D8E2B1D75F64581CCAD48DB4E4ADEF476E99D7D256ECE9DDEBE94D59F043B2BC8CE04C8DC71A1BDE376E4C85A022B8ADB4C4D2BBD33556D147A2087612C969DD045DA254B3930DFD91FA67378FB4ECE0032377491B2B2EA891781D005B037ACE63E200796940E2CB9110FAE7476056E8CEE213AFBACDAF5FCA47DC2E77AA5B3866B62FBECD0E251380DB368C380168FC26998451906B478144EC32CBA30A0C5A3701A66890C3DD100AACAC2178104D7755D8F0DB812774575E5E0F8244F3AD8FB755CA92159CA377DD22EE16014976208E4EC5A89741B251C4D3D19CDE82402447C0712174CDA2D48ED632359F13CBB04AC8588D5235DA8016D24232441244941410A8D01E0429A2A6903124881280AA5300A83200204C1C0A520A97FD47355DB8880623EF590DD3B450C66624929A228030EF850C0C2B200F391784A0B5A59F2A84396F3B5475688779C67EAC909B60D44D986EAE4F862E65D048A100FF2AF1703E4869C72157783D25B6ECDB3D8C612D2A955AA234E784E5E5343DD87EDE6E0BC3859CA9A0B858FD3EBC031CE0433E9DADEE852FE700D4F4D0EE1F2570FCF3EDADA0DEF67F55A28FED1561368D9B21E10A3DC3AA905800F308655D023DCC6', 3485, '{"version":1,"report":{"kind":"canonical","hasParentId":true,"entry":{"id":"migrated-tool-1","parentId":"migrated-assistant-1","timestamp":"2026-10-20T09:00:03.000Z","type":"message"}},"navigation":{"id":"migrated-tool-1","parentId":"migrated-assistant-1","timestamp":"2026-10-20T09:00:03.000Z","type":"message","message":{"role":"toolResult"}},"reset":{"id":"migrated-tool-1","parentId":"migrated-assistant-1","timestamp":"2026-10-20T09:00:03.000Z","type":"message","message":{"role":"toolResult"}},"model":{"id":"migrated-tool-1","parentId":"migrated-assistant-1","timestamp":"2026-10-20T09:00:03.000Z","type":"message","message":{"role":"toolResult"}},"modelBytes":3485,"modelWithoutCheckpointBytes":3485,"withoutCustomDataBytes":3485}');
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-migrated', 'migrated-tool-1', 4, 'message', 'migrated-assistant-1', 'fixture-tool-1', 1792486803000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-migrated', 3, 4, 2, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-migrated', 5, '{"type":"message","id":"migrated-assistant-2","parentId":"migrated-tool-1","timestamp":"2026-10-20T09:00:04.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai","model":"fixture-model","stopReason":"stop","timestamp":1792486804000,"idempotencyKey":"fixture-assistant-2","content":[{"type":"text","text":"The fixture repo has 40 files."}],"openclawDisplayContent":[{"type":"text","text":"The fixture repo has 40 files."}],"openclawStreamFallback":{"itemId":"fixture-item","replacementText":"The fixture repo has 40 files.","source":"segment"},"usage":{"input":200,"output":12,"cacheRead":0,"cacheWrite":0,"totalTokens":212,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"contextUsage":{"promptTokens":200,"state":"available","totalTokens":212}},"__openclaw":{"mirrorIdentity":"fixture-mirror","mirrorOrigin":"fixture-origin","runId":"fixture-run-1","runTerminal":true}}}', 1792486804000, NULL, 919, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-migrated', 'migrated-assistant-2', 5, 'message', 'migrated-tool-1', 'fixture-assistant-2', 1792486804000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-migrated', 4, 5, 3, 1);
INSERT INTO session_windows (session_id, session_key, created_at, updated_at, reason, started_at, ended_at, status, model, model_provider, agent_harness_id, display_name) VALUES ('openclaw-fixture-native', 'agent:main:explicit:openclaw-fixture-native', 1792490400000, 1792490404000, 'initial', 1792490400000, 1792490404000, 'done', 'fixture-model', 'openai', 'codex', 'Run pwd, then say hello');
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-native', 1, '{"type":"session","version":3,"id":"openclaw-fixture-native","timestamp":"2026-10-20T10:00:00.000Z","cwd":"/tmp/repo"}', 1792490400000, NULL, 118, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-native', 'openclaw-fixture-native', 1, 'session', NULL, NULL, 1792490400000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-native', 0, 1, NULL, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-native', 2, '{"type":"message","id":"native-user-1","parentId":null,"timestamp":"2026-10-20T10:00:01.000Z","message":{"role":"user","content":"Run pwd, then say hello","timestamp":1792490401000,"idempotencyKey":"fixture-user-2","__openclaw":{"senderIsOwner":true}}}', 1792490401000, NULL, 252, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-native', 'native-user-1', 2, 'message', NULL, 'fixture-user-2', 1792490401000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-native', 1, 2, 0, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-native', 3, '{"type":"message","id":"native-assistant-1","parentId":"native-user-1","timestamp":"2026-10-20T10:00:02.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai","model":"fixture-model","stopReason":"toolUse","timestamp":1792490402000,"idempotencyKey":"fixture-assistant-3","content":[{"type":"toolCall","id":"fixture-call-2","name":"bash","arguments":{"command":"pwd"}}],"usage":{"input":90,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":100,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}}', 1792490402000, NULL, 545, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-native', 'native-assistant-1', 3, 'message', 'native-user-1', 'fixture-assistant-3', 1792490402000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-native', 2, 3, 1, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-native', 4, '{"type":"message","id":"native-tool-1","parentId":"native-assistant-1","timestamp":"2026-10-20T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"fixture-call-2","toolName":"bash","isError":false,"timestamp":1792490403000,"idempotencyKey":"fixture-tool-2","content":[{"type":"text","text":"/tmp/repo"}],"details":{"status":"completed","exitCode":0,"exitSignal":null,"exitReason":"exit","durationMs":10,"aggregated":"/tmp/repo","noOutputTimedOut":false,"cwd":"/tmp/repo"}}}', 1792490403000, NULL, 481, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-native', 'native-tool-1', 4, 'message', 'native-assistant-1', 'fixture-tool-2', 1792490403000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-native', 3, 4, 2, 1);
INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('openclaw-fixture-native', 5, '{"type":"message","id":"native-assistant-2","parentId":"native-tool-1","timestamp":"2026-10-20T10:00:04.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai","model":"fixture-model","stopReason":"stop","timestamp":1792490404000,"idempotencyKey":"fixture-assistant-4","content":[{"type":"text","text":"Hello from /tmp/repo."}],"openclawDelivery":{"mediaUrls":[]},"usage":{"input":110,"output":8,"cacheRead":0,"cacheWrite":0,"totalTokens":118,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}}', 1792490404000, NULL, 539, NULL);
INSERT INTO transcript_event_identities (session_id, event_id, seq, event_type, parent_id, message_idempotency_key, created_at) VALUES ('openclaw-fixture-native', 'native-assistant-2', 5, 'message', 'native-tool-1', 'fixture-assistant-4', 1792490404000);
INSERT INTO session_transcript_active_events (session_id, active_position, event_seq, message_position, context_eligible) VALUES ('openclaw-fixture-native', 4, 5, 3, 1);
