import SwiftUI
import AppKit

extension PreferencesView {
    var openCodeTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OpenCode").font(.title2).fontWeight(.semibold)

            // Binary Source
            VStack(alignment: .leading, spacing: 10) {
                // Binary source segmented: Auto | Custom
                labeledRow("Binary Source") {
                    Picker("", selection: Binding(
                        get: { opencodeSettings.binaryPath.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                opencodeSettings.setBinaryPath("")
                                scheduleOpenCodeProbe()
                            } else {
                                // Custom: open file picker
                                pickOpenCodeBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Use the auto-detected OpenCode CLI or supply a custom path")
                }

                // Auto row (detected path + version + actions)
                if opencodeSettings.binaryPath.isEmpty {
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(opencodeVersionString ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = opencodeResolvedPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if opencodeProbeState == .failure && opencodeVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OpenCode CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install via pip: pip install opencode-ai")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeOpenCode() }
                            .buttonStyle(.bordered)
                            .help("Query the detected OpenCode CLI for its version")
                        Button("Copy Path") {
                            if let p = opencodeResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected OpenCode CLI path to clipboard")
                        .disabled(opencodeResolvedPath == nil)
                        Button("Reveal") {
                            if let p = opencodeResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected OpenCode CLI binary in Finder")
                        .disabled(opencodeResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/opencode", text: Binding(get: { opencodeSettings.binaryPath }, set: { opencodeSettings.setBinaryPath($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleOpenCodeProbe() }
                            .onChange(of: opencodeSettings.binaryPath) { _, _ in scheduleOpenCodeProbe() }
                            .help("Enter the full path to a custom OpenCode CLI binary")
                        Button("Choose…", action: pickOpenCodeBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the OpenCode CLI binary from the filesystem")
                        Button("Clear") {
                            opencodeSettings.setBinaryPath("")
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                }
            }

            // Sessions Directory (OpenCode)
            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $opencodeSessionsPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateOpenCodeSessionsPath()
                            commitOpenCodeSessionsPathIfValid()
                        }
                        .onChange(of: opencodeSessionsPath) { _, _ in
                            validateOpenCodeSessionsPath()
                            opencodeSessionsPathDebounce?.cancel()
                            let work = DispatchWorkItem { commitOpenCodeSessionsPathIfValid() }
                            opencodeSessionsPathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the OpenCode sessions directory. Leave blank to use the default location")

                    Button(action: pickOpenCodeSessionsFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory to store OpenCode session logs")
                }

                if !opencodeSessionsPathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Default: ~/.local/share/opencode/storage/session")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear {
            scheduleOpenCodeProbe()
        }
    }

    // MARK: - OpenCode Probe

    func probeOpenCode() {
        if opencodeProbeState == .probing { return }
        opencodeProbeState = .probing
        opencodeVersionString = nil
        opencodeResolvedPath = nil
        let override = opencodeSettings.binaryPath.isEmpty ? nil : opencodeSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = OpenCodeCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.opencodeVersionString = res.versionString
                    self.opencodeResolvedPath = res.binaryURL.path
                    self.opencodeProbeState = .success
                    let wasUnavailable = !self.openCodeCLIAvailable
                    self.openCodeCLIAvailable = true
                    if wasUnavailable {
                        self.showOpenCodeToolbarFilter = true
                    }
                case .failure:
                    self.opencodeVersionString = nil
                    self.opencodeResolvedPath = nil
                    self.opencodeProbeState = .failure
                    self.openCodeCLIAvailable = false
                    self.showOpenCodeToolbarFilter = false
                }
            }
        }
    }

    func scheduleOpenCodeProbe() {
        opencodeProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeOpenCode() }
        opencodeProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - OpenCode Pickers

    func pickOpenCodeBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select OpenCode CLI Binary"
        panel.message = "Choose the opencode executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        // Suggest common locations
        if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".local/bin")
        }

        if panel.runModal() == .OK, let url = panel.url {
            opencodeSettings.setBinaryPath(url.path)
            scheduleOpenCodeProbe()
        }
    }

    func pickOpenCodeSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select OpenCode Sessions Directory"
        panel.message = "Choose a folder where OpenCode session logs are stored"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        // Start at current override or default
        if !opencodeSessionsPath.isEmpty {
            let expanded = (opencodeSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".local/share/opencode/storage/session")
        }

        if panel.runModal() == .OK, let url = panel.url {
            opencodeSessionsPath = url.path
            validateOpenCodeSessionsPath()
            commitOpenCodeSessionsPathIfValid()
        }
    }

    // MARK: - OpenCode Path Validation

    func validateOpenCodeSessionsPath() {
        guard !opencodeSessionsPath.isEmpty else {
            opencodeSessionsPathValid = true
            return
        }
        let expanded = (opencodeSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        opencodeSessionsPathValid = exists && isDir.boolValue
    }

    func commitOpenCodeSessionsPathIfValid() {
        guard opencodeSessionsPathValid else { return }
        // The @AppStorage binding will automatically persist the value
        // OpenCodeSessionIndexer listens to UserDefaults changes and triggers its own refresh
    }
}
