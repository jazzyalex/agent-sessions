import SwiftUI
import AppKit

extension PreferencesView {
    var devinTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Devin").font(.title2).fontWeight(.semibold)

            if !devinAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Devin CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { devinSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    devinSettings.setBinaryPath("")
                                    scheduleDevinProbe()
                                } else {
                                    pickDevinBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Devin CLI or supply a custom path")
                    }

                    if devinSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(devinVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = devinResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if devinProbeState == .failure && devinVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Devin CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install it from code.devin.com and ensure `devin` is on PATH.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeDevin() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Devin CLI for its version")
                            Button("Copy Path") {
                                if let p = devinResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Devin CLI path to clipboard")
                            .disabled(devinResolvedPath == nil)
                            Button("Reveal") {
                                if let p = devinResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Devin CLI binary in Finder")
                            .disabled(devinResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/devin", text: Binding(get: { devinSettings.binaryPath }, set: { devinSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleDevinProbe() }
                                .onChange(of: devinSettings.binaryPath) { _, _ in scheduleDevinProbe() }
                                .help("Enter the full path to a custom Devin CLI binary")
                            Button("Choose...", action: pickDevinBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Devin CLI binary from the filesystem")
                        }
                        if !devinSettings.binaryPath.isEmpty, devinProbeState == .failure {
                            Text("Invalid Devin binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("Used for both the copied resume command and Resume in Terminal. Devin resumes by session id (`--resume`), falling back to `--continue` for the most recent conversation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .devin)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("~/.local/share/devin/cli")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $devinSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateDevinSessionsPath()
                                    commitDevinSessionsPathIfValid()
                                }
                                .onChange(of: devinSessionsPath) { _, _ in
                                    scheduleDevinSessionsPathValidation()
                                }
                            Button("Choose...", action: pickDevinSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Select a Devin sessions directory")
                        }
                    }

                    if !devinSessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Devin writes one wire.jsonl journal per agent under its sessions directory. Override only when you point DEVIN_CODE_HOME at a non-default location.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .onAppear {
            scheduleDevinProbe()
        }
    }

    func pickDevinBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Devin CLI Binary"
        panel.message = "Choose the devin executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            devinSettings.setBinaryPath(url.path)
            scheduleDevinProbe()
        }
    }

    func validateDevinSessionsPath() {
        guard !devinSessionsPath.isEmpty else {
            devinSessionsPathValid = true
            return
        }
        let expanded = (devinSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        devinSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitDevinSessionsPathIfValid() {
        guard devinSessionsPathValid else { return }
        UserDefaults.standard.set(devinSessionsPath, forKey: "DevinSessionsRootOverride")
    }

    func scheduleDevinSessionsPathValidation() {
        devinSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateDevinSessionsPath()
            commitDevinSessionsPathIfValid()
        }
        devinSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickDevinSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Devin Sessions Directory"
        panel.message = "Choose the Devin sessions folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !devinSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (devinSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devin/cli")
        }

        if panel.runModal() == .OK, let url = panel.url {
            devinSessionsPath = url.path
            validateDevinSessionsPath()
            commitDevinSessionsPathIfValid()
        }
    }
}
