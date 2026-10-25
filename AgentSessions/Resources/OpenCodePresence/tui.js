import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

export const publisher = "agent-sessions-opencode-tui";

// Poll the supported client-local route, not transcript dates or terminal titles.
export function snapshot(ctx, { pid = process.pid, now = new Date() } = {}) {
  const route = ctx.ui.router.current();
  const id = route.type === "session" ? route.sessionID : null;
  const selected = id ? ctx.data.session.get(id) : undefined;
  const location = selected?.location ?? ctx.location ?? ctx.data.location.default();
  return {
    schemaVersion: 1,
    publisher,
    source: "opencode",
    kind: "interactive",
    sessionId: id,
    workspaceRoot: location?.directory ?? process.cwd(),
    pid,
    lastSeenAt: now.toISOString(),
    activityState: id && ctx.data.session.status(id) === "running" ? "activeWorking" : "openIdle",
    terminal: {
      termProgram: process.env.TERM_PROGRAM,
      itermSessionId: process.env.ITERM_SESSION_ID,
    },
  };
}

export function start(ctx, {
  root = join(homedir(), "Library", "Application Support", "AgentSessions", "Presence"),
  interval = 1000,
  pid = process.pid,
} = {}) {
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const file = join(root, `opencode-tui-${pid}-${randomUUID()}.json`);
  const temporary = `${file}.tmp`;
  let reportedError = false;
  let stopped = false;
  function publish() {
    if (stopped) return;
    try {
      writeFileSync(temporary, JSON.stringify(snapshot(ctx, { pid })), { mode: 0o600 });
      renameSync(temporary, file);
    } catch (error) {
      if (!reportedError) {
        reportedError = true;
        ctx.ui.toast?.show({ variant: "error", message: `Agent Sessions presence: ${String(error)}` });
      }
    }
  }
  function cleanup() {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
    process.removeListener("exit", cleanup);
    for (const path of [file, temporary]) {
      try { unlinkSync(path); } catch (error) { if (error.code !== "ENOENT") console.error(error); }
    }
  }
  publish();
  const timer = setInterval(publish, interval);
  timer.unref?.();
  process.once("exit", cleanup);
  return cleanup;
}

export default {
  id: "agent-sessions.presence",
  setup(ctx) {
    if (typeof ctx.ui?.router?.current !== "function" || typeof ctx.data?.session?.status !== "function") return;
    return start(ctx);
  },
};
