import SwiftUI
import AppKit

extension PreferencesView {
    var qwenTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Qwen Code").font(.title2).fontWeight(.semibold)

            if !qwenAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Qwen Code Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { qwenSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { value in
                                if value == 0 {
                                    qwenSettings.setBinaryPath("")
                                    scheduleQwenProbe()
                                } else {
                                    pickQwenBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }

                    if qwenSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(qwenVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = qwenResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if qwenProbeState == .failure && qwenVersionString == nil {
                            PreferenceCallout {
                                Text("Qwen Code was not found. Ensure `qwen` is on PATH.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Check Version") { probeQwen() }.buttonStyle(.bordered)
                            Button("Copy Path") {
                                if let path = qwenResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(path, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(qwenResolvedPath == nil)
                            Button("Reveal") {
                                if let path = qwenResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(qwenResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/qwen", text: Binding(
                                get: { qwenSettings.binaryPath },
                                set: { qwenSettings.setBinaryPath($0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleQwenProbe() }
                            .onChange(of: qwenSettings.binaryPath) { _, _ in scheduleQwenProbe() }
                            Button("Choose...", action: pickQwenBinary).buttonStyle(.borderedProminent)
                        }
                        if qwenProbeState == .failure {
                            Text("Invalid Qwen Code binary path.").font(.caption).foregroundStyle(.red)
                        }
                    }

                    Text("Active chats use the installed CLI's advertised `--resume <id>` command, with `--continue` only when the session working directory is known. Archived chats remain browsable and searchable, but Qwen cannot resume them in place.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .qwen)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText).font(.caption)
                        }
                    }
                    labeledRow("Default Root") {
                        Text("~/.qwen/projects").font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $qwenSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateQwenSessionsPath()
                                    commitQwenSessionsPathIfValid()
                                }
                                .onChange(of: qwenSessionsPath) { _, _ in scheduleQwenSessionsPathValidation() }
                            Button("Choose...", action: pickQwenSessionsFolder).buttonStyle(.borderedProminent)
                        }
                    }
                    if !qwenSessionsPathValid {
                        Text("Choose an existing directory.").font(.caption).foregroundStyle(.red)
                    }
                    Text("Qwen Code stores one session-ID-named JSONL transcript per session below each project's chats directory. Override this only for a relocated QWEN_HOME or copied projects root. A copied root not named projects remains browse-only because the CLI cannot resolve it for resume.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("QWEN_RUNTIME_DIR is process-local and is not auto-detected. If you use it, choose that runtime directory's projects folder here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .onAppear { scheduleQwenProbe() }
    }

    func pickQwenBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Qwen Code Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the qwen executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            qwenSettings.setBinaryPath(url.path)
            scheduleQwenProbe()
        }
    }

    func validateQwenSessionsPath() {
        guard !qwenSessionsPath.isEmpty else {
            qwenSessionsPathValid = true
            return
        }
        let expanded = (qwenSessionsPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        qwenSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func commitQwenSessionsPathIfValid() {
        guard qwenSessionsPathValid else { return }
        UserDefaults.standard.set(qwenSessionsPath, forKey: QwenPreferencesKey.sessionsRootOverride)
    }

    func scheduleQwenSessionsPathValidation() {
        qwenSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateQwenSessionsPath()
            commitQwenSessionsPathIfValid()
        }
        qwenSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickQwenSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Qwen Code Projects Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the Qwen Code projects folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = qwenSessionsPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qwen/projects")
            : URL(fileURLWithPath: (qwenSessionsPath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            qwenSessionsPath = url.path
            validateQwenSessionsPath()
            commitQwenSessionsPathIfValid()
        }
    }
}
