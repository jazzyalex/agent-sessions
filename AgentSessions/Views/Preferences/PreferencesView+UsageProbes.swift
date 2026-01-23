import SwiftUI

extension PreferencesView {

    var usageProbesTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Usage Probes")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Runs lightweight terminal-based probes in dedicated working folders to refresh usage limits. Probe sessions are auto-generated /usage checks stored in a separate Claude project. Cleanup only removes validated probe sessions; your normal sessions are never touched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // No ephemeral in-pane messages; results are shown in modal dialogs only.

            // Debug visibility
            Toggle("Show system probe sessions for debugging", isOn: $showSystemProbeSessions)
                .toggleStyle(.switch)
                .help("Reveal probe sessions in the Sessions list. Leave OFF for normal use to avoid noise.")

            // Claude subsection
            sectionHeader("Claude")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("Refresh Claude usage now") {
                        isClaudeHardProbeRunning = true
                        ClaudeUsageModel.shared.hardProbeNowDiagnostics { diag in
                            isClaudeHardProbeRunning = false
                            if diag.success {
                                let m = ClaudeUsageModel.shared
                                var lines: [String] = []
                                lines.append("Result: SUCCESS")
                                lines.append("")
                                lines.append("Limits")
                                lines.append("5h:     \(m.sessionRemainingPercent)% remaining (\(m.sessionResetText))")
                                lines.append("Weekly: \(m.weekAllModelsRemainingPercent)% remaining (\(m.weekAllModelsResetText))")
                                claudeProbeMessage = lines.joined(separator: "\n")
                            } else {
                                var lines: [String] = []
                                lines.append("Result: FAILED")
                                lines.append("Exit code: \(diag.exitCode)")
                                lines.append("Script: \(diag.scriptPath)")
                                lines.append("WORKDIR: \(diag.workdir)")
                                lines.append("CLAUDE_BIN: \(diag.claudeBin ?? "<unset>")")
                                lines.append("TMUX_BIN: \(diag.tmuxBin ?? "<unset>")")
                                if let t = diag.timeoutSecs { lines.append("TIMEOUT_SECS: \(t)") }
                                lines.append("")
                                lines.append("— stdout —")
                                lines.append(diag.stdout.isEmpty ? "<empty>" : diag.stdout)
                                lines.append("")
                                lines.append("— stderr —")
                                lines.append(diag.stderr.isEmpty ? "<empty>" : diag.stderr)
                                claudeProbeMessage = lines.joined(separator: "\n")
                            }
                            showClaudeProbeResult = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Instantly refresh Claude usage data. Note: probing launches Claude Code and may count toward Claude Code usage limits.")

                    if isClaudeHardProbeRunning {
                        Text("Wait for probe result…")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("May count toward Claude Code usage limits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("", selection: Binding(
                    get: { claudeProbeCleanupMode },
                    set: { newVal in
                        if newVal == "auto" {
                            showConfirmAutoDelete = true
                        } else {
                            claudeProbeCleanupMode = "none"
                            ClaudeProbeProject.setCleanupMode(.none)
                        }
                    }
                )) {
                    Text("No delete").tag("none")
                    Text("Auto-delete after each probe").foregroundStyle(.red).tag("auto")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                HStack(spacing: 12) {
                    Button("Clean Claude probe sessions now") { showConfirmDeleteNow = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            // Hard-probe result dialog for Claude
            .alert("Claude /usage Probe", isPresented: $showClaudeProbeResult) {
                Button("Close", role: .cancel) {}
            } message: {
                Text(claudeProbeMessage)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.leading)
            }
            .alert("Enable Automatic Cleanup?", isPresented: $showConfirmAutoDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Enable", role: .destructive) {
                    claudeProbeCleanupMode = "auto"
                    ClaudeProbeProject.setCleanupMode(.auto)
                    showCleanupFlash("Claude auto-delete enabled. Will remove probe sessions after each probe.", color: .green)
                }
            } message: {
                Text("After each usage probe, only the dedicated Claude probe project is deleted once safety checks verify it contains only probe sessions.")
            }
            .alert("Delete Claude Probe Sessions Now?", isPresented: $showConfirmDeleteNow) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    let res = ClaudeProbeProject.cleanupNowUserInitiated()
                    // Inline feedback moved to a modal summary dialog below
                    handleCleanupResult(res, manual: true)
                }
            } message: {
                Text("Probe sessions are short /usage checks created by Agent Sessions in a dedicated Claude project. This cleanup only removes that probe project after validation, and never touches your normal Claude sessions.")
            }

            // Result summary dialog
            .alert("Claude Probe Cleanup", isPresented: $showClaudeCleanupResult) {
                Button("Close", role: .cancel) {}
            } message: {
                Text(claudeCleanupMessage)
            }

            // Codex subsection
            sectionHeader("Codex")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow auto /status probe when no recent sessions", isOn: $codexAllowStatusProbe)
                    .toggleStyle(.checkbox)
                    .help("When there are no recent Codex sessions (6+ hours) and the strip or menu bar is visible, ask Codex CLI (/status) via tmux for current usage.")
                HStack(spacing: 12) {
                    Button("Run hard Codex /status probe now") {
                        isCodexHardProbeRunning = true
                        CodexUsageModel.shared.hardProbeNowDiagnostics { diag in
                            isCodexHardProbeRunning = false
                            if diag.success {
                                let m = CodexUsageModel.shared
                                // Nicely formatted, monospaced-friendly block
                                var lines: [String] = []
                                lines.append("Result: SUCCESS")
                                lines.append("")
                                lines.append("Limits")
                                lines.append("5h:     \(m.fiveHourRemainingPercent)% remaining (\(m.fiveHourResetText))")
                                lines.append("Weekly: \(m.weekRemainingPercent)% remaining (\(m.weekResetText))")
                                codexProbeMessage = lines.joined(separator: "\n")
                            } else {
                                var lines: [String] = []
                                lines.append("Result: FAILED")
                                lines.append("Exit code: \(diag.exitCode)")
                                lines.append("Script: \(diag.scriptPath)")
                                lines.append("WORKDIR: \(diag.workdir)")
                                lines.append("CODEX_BIN: \(diag.codexBin ?? "<unset>")")
                                lines.append("TMUX_BIN: \(diag.tmuxBin ?? "<unset>")")
                                if let t = diag.timeoutSecs { lines.append("TIMEOUT_SECS: \(t)") }
                                lines.append("")
                                lines.append("— stdout —")
                                lines.append(diag.stdout.isEmpty ? "<empty>" : diag.stdout)
                                lines.append("")
                                lines.append("— stderr —")
                                lines.append(diag.stderr.isEmpty ? "<empty>" : diag.stderr)
                                codexProbeMessage = lines.joined(separator: "\n")
                            }
                            showCodexProbeResult = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Runs a one-off /status probe regardless of staleness or auto-probe setting, and shows the result.")

                    if isCodexHardProbeRunning {
                        Text("Wait for probe result…")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Consumes tokens for 1-2 messages")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text("Primary tracking remains the JSONL log parser; /status is a secondary source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { codexProbeCleanupMode },
                    set: { newVal in
                        if newVal == "auto" {
                            showConfirmCodexAutoDelete = true
                        } else {
                            codexProbeCleanupMode = "none"
                            CodexProbeCleanup.setCleanupMode(.none)
                        }
                    }
                )) {
                    Text("No delete").tag("none")
                    Text("Auto-delete after each probe").foregroundStyle(.red).tag("auto")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                HStack(spacing: 12) {
                    Button("Delete Codex probe sessions now") { showConfirmCodexDeleteNow = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .alert("Enable Automatic Cleanup?", isPresented: $showConfirmCodexAutoDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Enable", role: .destructive) {
                    codexProbeCleanupMode = "auto"
                    CodexProbeCleanup.setCleanupMode(.auto)
                    showCleanupFlash("Codex auto-delete enabled. Will remove probe sessions after each probe.", color: .green)
                }
            } message: {
                Text("After each status probe, only Codex probe sessions are deleted once safety checks verify they were created by Agent Sessions.")
            }
            .alert("Delete Codex Probe Sessions Now?", isPresented: $showConfirmCodexDeleteNow) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    let res = CodexProbeCleanup.cleanupNowUserInitiated()
                    handleCodexCleanupResult(res)
                }
            } message: {
                Text("Removes only Codex probe sessions after validation. If any session doesn’t look like a probe, nothing is deleted.")
            }

            // Result summary dialog for Codex (match Claude UX)
            .alert("Codex Probe Cleanup", isPresented: $showCodexCleanupResult) {
                Button("Close", role: .cancel) {}
            } message: {
                Text(codexCleanupMessage)
            }

            // Hard-probe result dialog
            .alert("Codex /status Probe", isPresented: $showCodexProbeResult) {
                Button("Close", role: .cancel) {}
            } message: {
                Text(codexProbeMessage)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.leading)
            }

        }
        .onReceive(NotificationCenter.default.publisher(for: CodexProbeCleanup.didRunCleanupNotification)) { note in
            guard let info = note.userInfo as? [String: Any], let status = info["status"] as? String else { return }
            let mode = (info["mode"] as? String) ?? "manual"
            if mode == "manual" {
                var lines: [String] = []
                switch status {
                case "success":
                    let deleted = (info["deleted"] as? Int) ?? 0
                    let skipped = (info["skipped"] as? Int) ?? 0
                    if let ts = info["oldest_ts"] as? Double {
                        let d = Date(timeIntervalSince1970: ts)
                        lines.append("Deleted: \(deleted)  Skipped: \(skipped)")
                        lines.append("Oldest deleted: \(AppDateFormatting.dateTimeShort(d))")
                    } else {
                        lines.append("Deleted: \(deleted)  Skipped: \(skipped)")
                    }
                    if deleted == 0 { lines.append("No Codex probe sessions were removed.") }
                case "not_found":
                    lines.append("No Codex probe sessions found to delete.")
                case "unsafe":
                    lines.append("Cleanup skipped: the sessions did not look like Agent Sessions probes.")
                case "io_error":
                    let msg = (info["message"] as? String) ?? "Unknown I/O error"
                    lines.append("Failed to delete Codex probe sessions.\n\n\(msg)")
                case "disabled":
                    lines.append("Codex probe session deletion is disabled by policy.")
                default:
                    break
                }
                codexCleanupMessage = lines.joined(separator: "\n")
                showCodexCleanupResult = true
            } else {
                // Auto mode: show a brief, non-intrusive flash
                switch status {
                case "success":
                    if let n = info["deleted"] as? Int { showCleanupFlash("Deleted \(n) Codex probe file(s).", color: .green) }
                    else { showCleanupFlash("Deleted Codex probe sessions.", color: .green) }
                case "not_found": showCleanupFlash("No Codex probe sessions to delete.", color: .secondary)
                case "unsafe": showCleanupFlash("Skipped: Codex sessions contained non-probe content.", color: .orange)
                case "io_error": showCleanupFlash("Failed to delete Codex probe sessions.", color: .red)
                case "disabled": break
                default: break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ClaudeProbeProject.didRunCleanupNotification)) { note in
            guard let info = note.userInfo as? [String: Any], let status = info["status"] as? String else { return }
            let mode = (info["mode"] as? String) ?? "manual"
            if mode == "manual" {
                var lines: [String] = []
                switch status {
                case "success":
                    let deleted = (info["deleted"] as? Int) ?? 0
                    let skipped = (info["skipped"] as? Int) ?? 0
                    if let ts = info["oldest_ts"] as? Double {
                        let d = Date(timeIntervalSince1970: ts)
                        lines.append("Deleted: \(deleted)  Skipped: \(skipped)")
                        lines.append("Oldest deleted: \(AppDateFormatting.dateTimeShort(d))")
                    } else {
                        lines.append("Deleted: \(deleted)  Skipped: \(skipped)")
                    }
                    if deleted == 0 { lines.append("No Claude probe sessions were removed.") }
                    claudeCleanupMessage = lines.joined(separator: "\n")
                    showClaudeCleanupResult = true
                case "not_found":
                    claudeCleanupMessage = "No Claude probe sessions found to delete."
                    showClaudeCleanupResult = true
                case "unsafe":
                    claudeCleanupMessage = "Cleanup skipped: the project contained sessions that don’t look like Agent Sessions probes."
                    showClaudeCleanupResult = true
                case "io_error":
                    let msg = (info["message"] as? String) ?? "Unknown I/O error"
                    claudeCleanupMessage = "Failed to delete Claude probe sessions.\n\n\(msg)"
                    showClaudeCleanupResult = true
                default:
                    break
                }
            } else {
                // Auto mode: remain non-intrusive; mirror Codex behavior with a brief flash.
                switch status {
                case "success":
                    if let n = info["deleted"] as? Int { showCleanupFlash("Deleted \(n) Claude probe file(s).", color: .green) }
                    else { showCleanupFlash("Deleted Claude probe sessions.", color: .green) }
                case "not_found":
                    showCleanupFlash("No Claude probe sessions to delete.", color: .secondary)
                case "unsafe":
                    showCleanupFlash("Skipped: Claude sessions contained non-probe content.", color: .orange)
                case "io_error":
                    showCleanupFlash("Failed to delete Claude probe sessions.", color: .red)
                case "disabled":
                    break
                default:
                    break
                }
            }
        }
    }

}
