import Foundation
import SwiftUI

enum ResumeHealthCheck {
    static func scriptBody() -> String {
        return #"""
#!/usr/bin/env bash
# resume_health_check.sh
# Validates a Codex CLI session JSONL, prints version, and tests both resume paths.
# Usage: ./resume_health_check.sh /absolute/path/to/session.jsonl [workdir] [timeout_seconds]

set -u

SESSION_PATH="${1:-}"
WORKDIR="${2:-}"
TIMEOUT_SECS="${3:-6}"

err() { echo "[ERROR] $*" >&2; }
ok()  { echo "[OK] $*"; }
info(){ echo "[INFO] $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

run_with_timeout() {
  local secs="$1"; shift
  "$@" > /tmp/codex_health_stdout.$$ 2>/tmp/codex_health_stderr.$$ &
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed+1))
    if [ "$elapsed" -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      echo "timeout after ${secs}s" >> /tmp/codex_health_stderr.$$
      return 124
    fi
  done
  wait "$pid"
  return $?
}

if [ -z "$SESSION_PATH" ]; then
  err "Missing required argument: /path/to/session.jsonl"; exit 2;
fi
if [ ! -e "$SESSION_PATH" ]; then err "Session file does not exist: $SESSION_PATH"; exit 3; fi
if [ ! -r "$SESSION_PATH" ]; then err "Session file is not readable: $SESSION_PATH"; exit 4; fi
if [ ! -s "$SESSION_PATH" ]; then err "Session file is empty (0 bytes): $SESSION_PATH"; exit 5; fi

if have jq; then
  info "Validating JSONL lines with jq…"
  head -n 200 "$SESSION_PATH" | jq -c . >/dev/null 2>&1 || { err "JSONL validation failed."; exit 6; }
  ok "JSONL structure looks valid (sampled)."
else
  info "jq not found; skipping JSONL structural check."
fi

CODEX_BIN="${CODEX_BIN:-codex}"
# Support absolute path or PATH lookup
if [[ "$CODEX_BIN" == /* ]]; then
  if [ ! -x "$CODEX_BIN" ]; then err "Provided CODEX_BIN is not executable: $CODEX_BIN"; exit 7; fi
else
  if ! have "$CODEX_BIN"; then err "Cannot find 'codex' in PATH. Set CODEX_BIN.\nPATH=$PATH"; exit 7; fi
fi

info "Detecting Codex CLI version…"
CODEX_VERSION="$($CODEX_BIN --version 2>&1 | head -n1)" || { err "Failed to run '$CODEX_BIN --version'."; exit 8; }
ok "Codex version: $CODEX_VERSION"

SESSION_ID=""
if have jq; then SESSION_ID="$(head -n 2000 "$SESSION_PATH" | jq -r 'select(has("session_id")) | .session_id' | head -n1 | tr -d '\r')"; fi
if [ -z "$SESSION_ID" ]; then SESSION_ID="$(grep -m1 -Eo '"session_id"\s*:\s*"[^"]+"' "$SESSION_PATH" | sed -E 's/.*"session_id"\s*:\s*"([^"]+)".*/\1/' | tr -d '\r')"; fi
if [ -n "$SESSION_ID" ]; then ok "Found session_id in JSONL: $SESSION_ID"; else info "No session_id found (testing explicit path)."; fi

CMD_PREFIX=""
if [ -n "$WORKDIR" ]; then
  if [ -d "$WORKDIR" ]; then CMD_PREFIX="cd \"$WORKDIR\" && "; ok "Using working directory: $WORKDIR"; else err "Provided workdir is not a directory: $WORKDIR"; exit 9; fi
fi

if [ -n "$SESSION_ID" ]; then
  info "Testing native resume by session_id (timeout ${TIMEOUT_SECS}s)…"
  run_with_timeout "$TIMEOUT_SECS" bash -lc "$CMD_PREFIX \"$CODEX_BIN\" resume \"$SESSION_ID\""
  NATIVE_STATUS=$?
  if [ $NATIVE_STATUS -eq 0 ] || [ $NATIVE_STATUS -eq 124 ]; then ok "Native resume path OK."; else err "Native resume failed rc=$NATIVE_STATUS"; fi
else
  info "Skipping native resume test (no session_id)."
fi

info "Testing explicit resume via -c experimental_resume (timeout ${TIMEOUT_SECS}s)…"
run_with_timeout "$TIMEOUT_SECS" bash -lc "$CMD_PREFIX \"$CODEX_BIN\" -c experimental_resume=\"$SESSION_PATH\""
EXP_STATUS=$?
if [ $EXP_STATUS -eq 0 ] || [ $EXP_STATUS -eq 124 ]; then ok "Explicit path resume OK."; else err "Explicit path resume failed rc=$EXP_STATUS"; fi

echo
info "Summary:"
printf "  Codex version      : %s\n" "$CODEX_VERSION"
printf "  Session file       : %s\n" "$SESSION_PATH"
printf "  Working directory  : %s\n" "${WORKDIR:-(none)}"
printf "  Native resume rc   : %s\n" "${NATIVE_STATUS:-skipped}"
printf "  Explicit resume rc : %s\n" "$EXP_STATUS"

# Treat 124 (timeout) as a healthy start for exit semantics
OK_NATIVE=1
if [ -n "${NATIVE_STATUS:-}" ]; then
  if [ "${NATIVE_STATUS}" -eq 0 ] || [ "${NATIVE_STATUS}" -eq 124 ]; then OK_NATIVE=0; fi
fi
OK_EXPLICIT=1
if [ "$EXP_STATUS" -eq 0 ] || [ "$EXP_STATUS" -eq 124 ]; then OK_EXPLICIT=0; fi

if [ -n "$SESSION_ID" ]; then
  if [ $OK_NATIVE -eq 0 ] || [ $OK_EXPLICIT -eq 0 ]; then exit 0; else exit 10; fi
else
  if [ $OK_EXPLICIT -eq 0 ]; then exit 0; else exit 11; fi
fi
"""#
    }

    static func run(sessionPath: String, workingDirectory: String?, codexBinary: URL?, timeoutSeconds: Int = 6) async -> (exitCode: Int32, output: String) {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resume_health_check.sh")
        do {
            try scriptBody().data(using: .utf8)?.write(to: scriptURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return (1, "Failed to write health-check script: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [scriptURL.path, sessionPath]
        if let workingDirectory, !workingDirectory.isEmpty {
            args.append(workingDirectory)
        } else {
            args.append("")
        }
        args.append(String(timeoutSeconds))
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let codexBinary { env["CODEX_BIN"] = codexBinary.path }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return (1, "Failed to run health-check: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, out)
    }
}
