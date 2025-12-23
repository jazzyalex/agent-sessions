import SwiftUI
import AppKit

extension PreferencesView {
    var copilotCLITab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Copilot CLI").font(.title2).fontWeight(.semibold)

            if !copilotAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General → Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Copilot CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { copilotSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    copilotSettings.setBinaryPath("")
                                    scheduleCopilotProbe()
                                } else {
                                    pickCopilotBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Copilot CLI or supply a custom path")
                    }

                    if copilotSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(copilotVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = copilotResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if copilotProbeState == .failure && copilotVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Copilot CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install via Homebrew or download from GitHub Copilot CLI releases.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeCopilot() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Copilot CLI for its version")
                            Button("Copy Path") {
                                if let p = copilotResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Copilot CLI path to clipboard")
                            .disabled(copilotResolvedPath == nil)
                            Button("Reveal") {
                                if let p = copilotResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Copilot CLI binary in Finder")
                            .disabled(copilotResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/copilot", text: Binding(get: { copilotSettings.binaryPath }, set: { copilotSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleCopilotProbe() }
                                .onChange(of: copilotSettings.binaryPath) { _, _ in scheduleCopilotProbe() }
                                .help("Enter the full path to a custom Copilot CLI binary")
                            Button("Choose…", action: pickCopilotBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Copilot CLI binary from the filesystem")
                        }
                        if !copilotSettings.binaryPath.isEmpty, copilotProbeState == .failure {
                            Text("Invalid Copilot binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                sectionHeader("Sessions Folder")
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("~/.copilot/session-state", text: $copilotSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit {
                                    validateCopilotSessionsPath()
                                    commitCopilotSessionsPathIfValid()
                                }
                                .onChange(of: copilotSessionsPath) { _, _ in
                                    copilotSessionsPathDebounce?.cancel()
                                    let work = DispatchWorkItem {
                                        validateCopilotSessionsPath()
                                        commitCopilotSessionsPathIfValid()
                                    }
                                    copilotSessionsPathDebounce = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                                }
                                .help("Override where Agent Sessions scans for Copilot session-state JSONL files")
                            Button("Choose…", action: pickCopilotSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Pick a folder to scan for Copilot sessions")
                        }
                    }

                    if !copilotSessionsPathValid {
                        Text("Folder does not exist or is not a directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Default: ~/.copilot/session-state")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!copilotAgentEnabled)

            Spacer()
        }
        .onAppear {
            scheduleCopilotProbe()
        }
    }

    // MARK: - Copilot Probe

    func probeCopilot() {
        if copilotProbeState == .probing { return }
        copilotProbeState = .probing
        copilotVersionString = nil
        copilotResolvedPath = nil
        let override = copilotSettings.binaryPath.isEmpty ? nil : copilotSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = CopilotCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.copilotVersionString = res.versionString
                    self.copilotResolvedPath = res.binaryURL.path
                    self.copilotProbeState = .success
                    self.copilotCLIAvailable = true
                case .failure:
                    self.copilotVersionString = nil
                    self.copilotResolvedPath = nil
                    self.copilotProbeState = .failure
                    self.copilotCLIAvailable = false
                }
            }
        }
    }

    // MARK: - Copilot Pickers

    func pickCopilotBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Copilot CLI Binary"
        panel.message = "Choose the copilot executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        // Suggest common locations
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            copilotSettings.setBinaryPath(url.path)
            scheduleCopilotProbe()
        }
    }

    func pickCopilotSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Copilot Sessions Directory"
        panel.message = "Choose a folder where Copilot session-state logs are stored"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !copilotSessionsPath.isEmpty {
            let expanded = (copilotSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".copilot/session-state")
        }

        if panel.runModal() == .OK, let url = panel.url {
            copilotSessionsPath = url.path
            validateCopilotSessionsPath()
            commitCopilotSessionsPathIfValid()
        }
    }

    // MARK: - Copilot Path Validation

    func validateCopilotSessionsPath() {
        guard !copilotSessionsPath.isEmpty else {
            copilotSessionsPathValid = true
            return
        }
        let expanded = (copilotSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        copilotSessionsPathValid = exists && isDir.boolValue
    }

    func commitCopilotSessionsPathIfValid() {
        guard copilotSessionsPathValid else { return }
        // @AppStorage persists automatically; indexers update on refresh.
    }
}

