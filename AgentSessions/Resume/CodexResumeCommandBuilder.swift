import Foundation

struct CodexResumeCommandBuilder {
    struct CommandPackage {
        let shellCommand: String
        let displayCommand: String
        let workingDirectory: URL?
    }

    enum BuildError: Error {
        case missingSessionID
        case missingSessionFile
    }

    @MainActor
    func makeCommand(for session: Session,
                     settings: CodexResumeSettings,
                     binaryURL: URL,
                     fallbackPath: URL?,
                     attemptResumeFirst: Bool) throws -> CommandPackage {
        // Prefer internal session_id from JSONL when available; fallback to filename UUID
        guard let sessionID = (session.codexInternalSessionID ?? session.codexFilenameUUID) else {
            throw BuildError.missingSessionID
        }

        let workingDirPath = settings.effectiveWorkingDirectory(for: session)
        let workingDirURL = workingDirPath.flatMap { URL(fileURLWithPath: $0) }
        let quotedSessionID = shellQuote(sessionID)
        let codexPath = shellQuote(binaryURL.path)

        let command: String
        if let fallback = fallbackPath {
            let quotedFallback = shellQuote(fallback.path)
            let explicitCommand = "\(codexPath) -c experimental_resume=\(quotedFallback)"
            if attemptResumeFirst {
                let resumeCommand = "\(codexPath) resume \(quotedSessionID)"
                // Add belt-and-suspenders third attempt for builds that require both flags
                let combined = "\(codexPath) -c experimental_resume=\(quotedFallback) resume \(quotedSessionID)"
                command = "\(resumeCommand) || \(explicitCommand) || \(combined)"
            } else {
                command = explicitCommand
            }
        } else {
            command = "\(codexPath) resume \(quotedSessionID)"
        }

        let shouldWritePresence: Bool = {
            let d = UserDefaults.standard
            if let v = d.object(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) as? Bool { return v }
            return true
        }()
        let registryRootOverride = UserDefaults.standard.string(forKey: PreferencesKey.Cockpit.codexActiveRegistryRootOverride)
        let maybeWrappedCommand: String = {
            guard shouldWritePresence else { return command }
            guard settings.launchMode != .embedded else { return command }
            return wrapWithActivePresence(command: command,
                                         sessionID: sessionID,
                                         sessionLogPath: session.filePath,
                                         workspaceRoot: workingDirPath,
                                         registryRootOverride: registryRootOverride)
        }()

        let shell: String
        if let workingDirPath, !workingDirPath.isEmpty {
            shell = "cd \(shellQuote(workingDirPath)) && \(maybeWrappedCommand)"
        } else {
            shell = maybeWrappedCommand
        }

        return CommandPackage(shellCommand: shell,
                              displayCommand: command,
                              workingDirectory: workingDirURL)
    }

    private func shellQuote(_ string: String) -> String {
        // Wrap in single quotes and escape existing single quotes using POSIX convention
        if string.isEmpty { return "''" }
        if !string.contains("'") {
            return "'\(string)'"
        }
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func wrapWithActivePresence(command: String,
                                        sessionID: String,
                                        sessionLogPath: String,
                                        workspaceRoot: String?,
                                        registryRootOverride: String?) -> String {
        let sid = shellQuote(sessionID)
        let log = shellQuote(sessionLogPath)
        let work = shellQuote(workspaceRoot ?? "")
        let override = shellQuote(registryRootOverride ?? "")

        // One-line, zsh-compatible wrapper that:
        // 1) writes a local presence file under CODEX_HOME/active (or override)
        // 2) heartbeats while Codex runs
        // 3) removes the entry on exit (TTL handles crashes)
        let segments: [String] = [
            "umask 077",
            "AS_SESSION_ID=\(sid)",
            "AS_SESSION_LOG=\(log)",
            "AS_WORKSPACE_ROOT=\(work)",
            "AS_ACTIVE_DIR_OVERRIDE=\(override)",
            "AS_STARTED_AT=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"",
            "json_escape(){ local s=\"$1\"; s=\"${s//\\\\/\\\\\\\\}\"; s=\"${s//\\\"/\\\\\\\"}\"; printf '%s' \"$s\"; }",
            "AS_ACTIVE_DIR=\"\"",
            "if [ -n \"$AS_ACTIVE_DIR_OVERRIDE\" ]; then AS_ACTIVE_DIR=\"$AS_ACTIVE_DIR_OVERRIDE\"; elif [ -n \"$CODEX_HOME\" ]; then AS_ACTIVE_DIR=\"$CODEX_HOME/active\"; else AS_ACTIVE_DIR=\"$HOME/.codex/active\"; fi",
            "mkdir -p \"$AS_ACTIVE_DIR\" >/dev/null 2>&1 || true",
            "chmod 700 \"$AS_ACTIVE_DIR\" >/dev/null 2>&1 || true",
            "AS_ACTIVE_FILE=\"$AS_ACTIVE_DIR/as-$$.json\"",
            "AS_HB_PID=\"\"",
            "cleanup(){ if [ -n \"$AS_HB_PID\" ]; then kill \"$AS_HB_PID\" >/dev/null 2>&1 || true; fi; rm -f \"$AS_ACTIVE_FILE\" >/dev/null 2>&1 || true; }",
            "trap cleanup EXIT INT TERM",
            "write_presence(){ local now=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"; local ttyv=\"$(tty 2>/dev/null || true)\"; case \"$ttyv\" in not*tty*) ttyv=\"\";; esac; local term=\"${TERM_PROGRAM:-}\"; local iterm=\"${ITERM_SESSION_ID:-}\"; local reveal=\"\"; if [ -n \"$iterm\" ]; then reveal=\"iterm2:///reveal?sessionid=$iterm\"; fi; local tmp=\"${AS_ACTIVE_FILE}.tmp\"; printf '{\"schema_version\":1,\"publisher\":\"agent-sessions-shim\",\"kind\":\"interactive\",\"session_id\":\"%s\",\"session_log_path\":\"%s\",\"workspace_root\":\"%s\",\"pid\":%d,\"tty\":\"%s\",\"started_at\":\"%s\",\"last_seen_at\":\"%s\",\"terminal\":{\"term_program\":\"%s\",\"iterm_session_id\":\"%s\",\"reveal_url\":\"%s\"}}' \"$(json_escape \"$AS_SESSION_ID\")\" \"$(json_escape \"$AS_SESSION_LOG\")\" \"$(json_escape \"$AS_WORKSPACE_ROOT\")\" \"$$\" \"$(json_escape \"$ttyv\")\" \"$(json_escape \"$AS_STARTED_AT\")\" \"$(json_escape \"$now\")\" \"$(json_escape \"$term\")\" \"$(json_escape \"$iterm\")\" \"$(json_escape \"$reveal\")\" > \"$tmp\" && mv -f \"$tmp\" \"$AS_ACTIVE_FILE\"; }",
            "write_presence",
            "( while :; do sleep 2; write_presence; done ) & AS_HB_PID=$!",
            command
        ]

        return "( " + segments.joined(separator: "; ") + " )"
    }
}
