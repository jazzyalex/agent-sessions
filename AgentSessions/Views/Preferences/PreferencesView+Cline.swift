import SwiftUI
import AppKit

extension PreferencesView {
    var clineTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cline").font(.title2).fontWeight(.semibold)

            if !clineAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Cline CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { clineSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    clineSettings.setBinaryPath("")
                                    scheduleClineProbe()
                                } else {
                                    pickClineBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Cline CLI or supply a custom path")
                    }

                    if clineSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(clineVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = clineResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if clineProbeState == .failure && clineVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cline CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install the Cline CLI and ensure `cline` is on PATH. Desktop sessions are found without the CLI when ~/.cline/data/sessions exists.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeCline() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Cline CLI for its version")
                            Button("Copy Path") {
                                if let p = clineResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Cline CLI path to clipboard")
                            .disabled(clineResolvedPath == nil)
                            Button("Reveal") {
                                if let p = clineResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Cline CLI binary in Finder")
                            .disabled(clineResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/cline", text: Binding(get: { clineSettings.binaryPath }, set: { clineSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleClineProbe() }
                                .onChange(of: clineSettings.binaryPath) { _, _ in scheduleClineProbe() }
                                .help("Enter the full path to a custom Cline CLI binary")
                            Button("Choose...", action: pickClineBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Cline CLI binary from the filesystem")
                        }
                        if !clineSettings.binaryPath.isEmpty, clineProbeState == .failure {
                            Text("Invalid Cline binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("Cline sessions are browsed locally. Resume in Terminal is not offered for this source.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .cline)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("$CLINE_DATA_DIR/sessions, or ~/.cline/data/sessions")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $clineSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateClineSessionsPath()
                                    commitClineSessionsPathIfValid()
                                }
                                .onChange(of: clineSessionsPath) { _, _ in
                                    scheduleClineSessionsPathValidation()
                                }
                            Button("Choose...", action: pickClineSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Select a Cline sessions directory")
                        }
                    }

                    if !clineSessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Cline writes one directory per session under its sessions root, holding <session-id>.json (the manifest) beside <session-id>.messages.json (the transcript). A custom root overrides both CLINE_DATA_DIR and the fallback path.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .onAppear {
            clineSessionsPath = UserDefaults.standard.string(forKey: ClinePreferencesKey.sessionsRootOverride) ?? ""
            validateClineSessionsPath()
            scheduleClineProbe()
        }
    }

    func pickClineBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Cline CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the cline executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            clineSettings.setBinaryPath(url.path)
            scheduleClineProbe()
        }
    }

    func validateClineSessionsPath() {
        clineSessionsPathValid = ClineSessionsRootPreference.isValid(clineSessionsPath)
    }

    func commitClineSessionsPathIfValid() {
        guard clineSessionsPathValid else { return }
        _ = ClineSessionsRootPreference.commit(clineSessionsPath)
    }

    func scheduleClineSessionsPathValidation() {
        clineSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateClineSessionsPath()
            commitClineSessionsPathIfValid()
        }
        clineSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickClineSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Cline Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the Cline sessions folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !clineSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (clineSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cline/data/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            clineSessionsPath = url.path
            validateClineSessionsPath()
            commitClineSessionsPathIfValid()
        }
    }
}
