import SwiftUI
import AppKit

extension PreferencesView {
    var kimiTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Kimi Code").font(.title2).fontWeight(.semibold)

            if !kimiAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Kimi Code CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { kimiSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    kimiSettings.setBinaryPath("")
                                    scheduleKimiProbe()
                                } else {
                                    pickKimiBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Kimi Code CLI or supply a custom path")
                    }

                    if kimiSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(kimiVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = kimiResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if kimiProbeState == .failure && kimiVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Kimi Code CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install it from code.kimi.com and ensure `kimi` is on PATH.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeKimi() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Kimi Code CLI for its version")
                            Button("Copy Path") {
                                if let p = kimiResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Kimi Code CLI path to clipboard")
                            .disabled(kimiResolvedPath == nil)
                            Button("Reveal") {
                                if let p = kimiResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Kimi Code CLI binary in Finder")
                            .disabled(kimiResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/kimi", text: Binding(get: { kimiSettings.binaryPath }, set: { kimiSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleKimiProbe() }
                                .onChange(of: kimiSettings.binaryPath) { _, _ in scheduleKimiProbe() }
                                .help("Enter the full path to a custom Kimi Code CLI binary")
                            Button("Choose...", action: pickKimiBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Kimi Code CLI binary from the filesystem")
                        }
                        if !kimiSettings.binaryPath.isEmpty, kimiProbeState == .failure {
                            Text("Invalid Kimi Code binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("Used for both the copied resume command and Resume in Terminal. Kimi resumes by session id (`--session`), falling back to `--continue` for the working directory.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .kimi)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("~/.kimi-code/sessions")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $kimiSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateKimiSessionsPath()
                                    commitKimiSessionsPathIfValid()
                                }
                                .onChange(of: kimiSessionsPath) { _, _ in
                                    scheduleKimiSessionsPathValidation()
                                }
                            Button("Choose...", action: pickKimiSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Select a Kimi Code sessions directory")
                        }
                    }

                    if !kimiSessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Kimi Code writes one wire.jsonl journal per agent under its sessions directory. Override only when you point KIMI_CODE_HOME at a non-default location.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .onAppear {
            scheduleKimiProbe()
        }
    }

    func pickKimiBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Kimi Code CLI Binary"
        panel.message = "Choose the kimi executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            kimiSettings.setBinaryPath(url.path)
            scheduleKimiProbe()
        }
    }

    func validateKimiSessionsPath() {
        guard !kimiSessionsPath.isEmpty else {
            kimiSessionsPathValid = true
            return
        }
        let expanded = (kimiSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        kimiSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitKimiSessionsPathIfValid() {
        guard kimiSessionsPathValid else { return }
        UserDefaults.standard.set(kimiSessionsPath, forKey: PreferencesKey.Paths.kimiSessionsRootOverride)
    }

    func scheduleKimiSessionsPathValidation() {
        kimiSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateKimiSessionsPath()
            commitKimiSessionsPathIfValid()
        }
        kimiSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickKimiSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Kimi Code Sessions Directory"
        panel.message = "Choose the Kimi Code sessions folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !kimiSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (kimiSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            kimiSessionsPath = url.path
            validateKimiSessionsPath()
            commitKimiSessionsPathIfValid()
        }
    }
}
