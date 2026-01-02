import SwiftUI
import AppKit

extension PreferencesView {
    var droidCLITab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Droid").font(.title2).fontWeight(.semibold)

            if !droidAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General → Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Droid CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { droidSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    droidSettings.setBinaryPath("")
                                    scheduleDroidProbe()
                                } else {
                                    pickDroidBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Droid CLI or supply a custom path")
                    }

                    if droidSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(droidVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = droidResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if droidProbeState == .failure && droidVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Droid CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install Droid (Factory CLI) and ensure `droid` is available on your PATH, or set a custom binary path here.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeDroid() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Droid CLI for its version")
                            Button("Copy Path") {
                                if let p = droidResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Droid CLI path to clipboard")
                            .disabled(droidResolvedPath == nil)
                            Button("Reveal") {
                                if let p = droidResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Droid CLI binary in Finder")
                            .disabled(droidResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/droid", text: Binding(get: { droidSettings.binaryPath }, set: { droidSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleDroidProbe() }
                                .onChange(of: droidSettings.binaryPath) { _, _ in scheduleDroidProbe() }
                                .help("Enter the full path to a custom Droid CLI binary")
                            Button("Choose…", action: pickDroidBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Droid CLI binary from the filesystem")
                        }

                        if droidProbeState == .failure {
                            Text("Unable to execute the specified binary. Check the path and try again.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                sectionHeader("Sessions Directory")
                VStack(alignment: .leading, spacing: 8) {
                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("~/.factory/sessions", text: $droidSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit {
                                    validateDroidSessionsPath()
                                    commitDroidSessionsPathIfValid()
                                }
                                .onChange(of: droidSessionsPath) { _, _ in
                                    droidSessionsPathDebounce?.cancel()
                                    let work = DispatchWorkItem {
                                        validateDroidSessionsPath()
                                        commitDroidSessionsPathIfValid()
                                    }
                                    droidSessionsPathDebounce = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                                }
                                .help("Override where Agent Sessions scans for Droid interactive session JSONL files")
                            Button("Choose…", action: pickDroidSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Pick a folder to scan for Droid sessions")
                        }
                    }

                    if !droidSessionsPathValid {
                        Text("Folder does not exist or is not a directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Default: ~/.factory/sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                sectionHeader("Projects Directory")
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    labeledRow("Search Root") {
                        HStack(spacing: 10) {
                            TextField("~/.factory/projects", text: $droidProjectsPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit {
                                    validateDroidProjectsPath()
                                    commitDroidProjectsPathIfValid()
                                }
                                .onChange(of: droidProjectsPath) { _, _ in
                                    droidProjectsPathDebounce?.cancel()
                                    let work = DispatchWorkItem {
                                        validateDroidProjectsPath()
                                        commitDroidProjectsPathIfValid()
                                    }
                                    droidProjectsPathDebounce = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                                }
                                .help(Text(verbatim: "Optional: scan for exported droid exec --output-format stream-json logs stored as JSONL"))
                            Button("Choose…", action: pickDroidProjectsFolder)
                                .buttonStyle(.bordered)
                                .help("Pick a projects folder to scan for stream-json logs")
                        }
                    }

                    if !droidProjectsPathValid {
                        Text("Folder does not exist or is not a directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Default: ~/.factory/projects (best-effort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Agent Sessions will only import files that match Droid’s stream-json schema to avoid false positives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!droidAgentEnabled)
        }
        .onAppear {
            scheduleDroidProbe()
        }
    }
}

extension PreferencesView {
    func pickDroidBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Droid CLI Binary"
        panel.message = "Choose the droid executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            droidSettings.setBinaryPath(url.path)
            scheduleDroidProbe()
        }
    }

    func pickDroidSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Droid Sessions Directory"
        panel.message = "Choose a folder where Droid session logs are stored"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !droidSessionsPath.isEmpty {
            let expanded = (droidSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            droidSessionsPath = url.path
            validateDroidSessionsPath()
            commitDroidSessionsPathIfValid()
        }
    }

    func pickDroidProjectsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Droid Projects Directory"
        panel.message = "Choose a folder to scan for stream-json logs"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !droidProjectsPath.isEmpty {
            let expanded = (droidProjectsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory/projects")
        }

        if panel.runModal() == .OK, let url = panel.url {
            droidProjectsPath = url.path
            validateDroidProjectsPath()
            commitDroidProjectsPathIfValid()
        }
    }

    func validateDroidSessionsPath() {
        guard !droidSessionsPath.isEmpty else {
            droidSessionsPathValid = true
            return
        }
        let expanded = (droidSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        droidSessionsPathValid = exists && isDir.boolValue
    }

    func validateDroidProjectsPath() {
        guard !droidProjectsPath.isEmpty else {
            droidProjectsPathValid = true
            return
        }
        let expanded = (droidProjectsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        droidProjectsPathValid = exists && isDir.boolValue
    }

    func commitDroidSessionsPathIfValid() {
        guard droidSessionsPathValid else { return }
        // @AppStorage persists automatically; indexers update on refresh.
    }

    func commitDroidProjectsPathIfValid() {
        guard droidProjectsPathValid else { return }
        // @AppStorage persists automatically; indexers update on refresh.
    }
}
