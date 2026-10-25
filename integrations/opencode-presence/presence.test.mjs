import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { snapshot, start } from "./tui.js";

function context() {
  const state = { route: { type: "session", sessionID: "ses_older" }, status: "idle" };
  const ctx = {
    ui: { router: { current: () => state.route }, toast: { show: assert.fail } },
    data: {
      session: { get: () => ({ location: { directory: "/example/project" } }), status: () => state.status },
      location: { default: () => ({ directory: "/fallback" }) },
    },
  };
  return { ctx, state };
}

test("exact route ID survives duplicate titles, session switching and Home", () => {
  const { ctx, state } = context();
  assert.equal(snapshot(ctx).sessionId, "ses_older");
  assert.equal(snapshot(ctx).activityState, "openIdle");
  state.route = { type: "session", sessionID: "ses_newer" };
  state.status = "running";
  assert.equal(snapshot(ctx).sessionId, "ses_newer");
  assert.equal(snapshot(ctx).activityState, "activeWorking");
  state.route = { type: "home" };
  assert.equal(snapshot(ctx).sessionId, null);
  assert.equal(snapshot(ctx).activityState, "openIdle");
});

test("atomic private heartbeat follows current selection and cleanup removes only this client", async () => {
  const root = mkdtempSync(join(tmpdir(), "agent-sessions-presence-"));
  const { ctx, state } = context();
  const stop = start(ctx, { root, interval: 10, pid: process.pid });
  const other = start(ctx, { root, interval: 10, pid: process.pid });
  try {
    const files = readdirSync(root).filter(x => x.endsWith(".json"));
    assert.equal(files.length, 2);
    assert.equal(statSync(join(root, files[0])).mode & 0o777, 0o600);
    state.route = { type: "session", sessionID: "ses_switched" };
    await new Promise(resolve => setTimeout(resolve, 35));
    for (const file of files) assert.equal(JSON.parse(readFileSync(join(root, file))).sessionId, "ses_switched");
    stop();
    assert.equal(readdirSync(root).filter(x => x.endsWith(".json")).length, 1);
    other();
    assert.deepEqual(readdirSync(root), []);
  } finally { stop(); other(); rmSync(root, { recursive: true }); }
});
