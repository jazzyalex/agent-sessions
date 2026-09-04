import SwiftUI
import AppKit

extension PreferencesView {
    var fxTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("fx").font(.title2).fontWeight(.semibold)

            if !fxAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("fx CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { fxSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    fxSettings.setBinaryPath("")
                                    scheduleFxProbe()
                                } else {
                                    pickFxBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected fx CLI or supply a custom path")
                    }

                    if fxSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(fxVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = fxResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if fxProbeState == .failure && fxVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("fx CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install it from fx.sh and ensure `fx` is on PATH.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeFx() }
                                .buttonStyle(.bordered)
                                .help("Query the detected fx CLI for its version")
                            Button("Copy Path") {
                                if let p = fxResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected fx CLI path to clipboard")
                            .disabled(fxResolvedPath == nil)
                            Button("Reveal") {
                                if let p = fxResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected fx CLI binary in Finder")
                            .disabled(fxResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/fx", text: Binding(get: { fxSettings.binaryPath }, set: { fxSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleFxProbe() }
                                .onChange(of: fxSettings.binaryPath) { _, _ in scheduleFxProbe() }
                                .help("Enter the full path to a custom fx CLI binary")
                            Button("Choose...", action: pickFxBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the fx CLI binary from the filesystem")
                        }
                        if !fxSettings.binaryPath.isEmpty, fxProbeState == .failure {
                            Text("Invalid fx binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("Used for both the copied resume command and Resume in Terminal. fx resumes by session id (`--resume`), falling back to `--continue` for the latest session in the workspace.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .fx)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("~/.fx/sessions")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $fxSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateFxSessionsPath()
                                    commitFxSessionsPathIfValid()
                                }
                                .onChange(of: fxSessionsPath) { _, _ in
                                    scheduleFxSessionsPathValidation()
                                }
                            Button("Choose...", action: pickFxSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Select an fx sessions directory")
                        }
                    }

                    if !fxSessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("fx writes one directory per session under its sessions root, holding checkpoint.json (the conversation) beside session.json. Override only when that data lives outside the default location; the root may point at the sessions directory or the .fx data directory itself.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .onAppear {
            scheduleFxProbe()
        }
    }

    func pickFxBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select fx CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the fx executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            fxSettings.setBinaryPath(url.path)
            scheduleFxProbe()
        }
    }

    func validateFxSessionsPath() {
        guard !fxSessionsPath.isEmpty else {
            fxSessionsPathValid = true
            return
        }
        let expanded = (fxSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        fxSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitFxSessionsPathIfValid() {
        guard fxSessionsPathValid else { return }
        UserDefaults.standard.set(fxSessionsPath, forKey: FxPreferencesKey.sessionsRootOverride)
    }

    func scheduleFxSessionsPathValidation() {
        fxSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateFxSessionsPath()
            commitFxSessionsPathIfValid()
        }
        fxSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickFxSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select fx Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the fx sessions folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !fxSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (fxSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fx/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            fxSessionsPath = url.path
            validateFxSessionsPath()
            commitFxSessionsPathIfValid()
        }
    }
}
