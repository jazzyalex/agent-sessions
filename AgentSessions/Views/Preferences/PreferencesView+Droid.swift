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
                                .help("Optional: scan for exported `droid exec --output-format stream-json` logs stored as JSONL")
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
    }
}

extension PreferencesView {
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

