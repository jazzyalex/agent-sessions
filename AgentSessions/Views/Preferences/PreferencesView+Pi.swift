import SwiftUI
import AppKit

extension PreferencesView {
    var piTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pi").font(.title2).fontWeight(.semibold)

            if !piAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Pi CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { piSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    piSettings.setBinaryPath("")
                                    schedulePiProbe()
                                } else {
                                    pickPiBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Pi CLI or supply a custom path")
                    }

                    if piSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(piVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = piResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if piProbeState == .failure && piVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Pi CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install Pi from pi.dev and ensure `pi` is on PATH.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probePi() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Pi CLI for its version")
                            Button("Copy Path") {
                                if let p = piResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Pi CLI path to clipboard")
                            .disabled(piResolvedPath == nil)
                            Button("Reveal") {
                                if let p = piResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Pi CLI binary in Finder")
                            .disabled(piResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/pi", text: Binding(get: { piSettings.binaryPath }, set: { piSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { schedulePiProbe() }
                                .onChange(of: piSettings.binaryPath) { _, _ in schedulePiProbe() }
                                .help("Enter the full path to a custom Pi CLI binary")
                            Button("Choose...", action: pickPiBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Pi CLI binary from the filesystem")
                        }
                        if !piSettings.binaryPath.isEmpty, piProbeState == .failure {
                            Text("Invalid Pi binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .pi)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("~/.pi/agent/sessions")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $piSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validatePiSessionsPath()
                                    commitPiSessionsPathIfValid()
                                }
                                .onChange(of: piSessionsPath) { _, _ in
                                    schedulePiSessionsPathValidation()
                                }
                            Button("Choose...", action: pickPiSessionsFolder)
                                .buttonStyle(.borderedProminent)
                                .help("Select a Pi sessions directory")
                        }
                    }

                    if !piSessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Pi writes JSONL v3 session files under its sessions directory. Override only when you use a non-default Pi agent directory.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .onAppear {
            schedulePiProbe()
        }
    }

    func pickPiBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Pi CLI Binary"
        panel.message = "Choose the pi executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            piSettings.setBinaryPath(url.path)
            schedulePiProbe()
        }
    }

    func validatePiSessionsPath() {
        guard !piSessionsPath.isEmpty else {
            piSessionsPathValid = true
            return
        }
        let expanded = (piSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        piSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitPiSessionsPathIfValid() {
        guard piSessionsPathValid else { return }
        UserDefaults.standard.set(piSessionsPath, forKey: PreferencesKey.Paths.piSessionsRootOverride)
    }

    func schedulePiSessionsPathValidation() {
        piSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validatePiSessionsPath()
            commitPiSessionsPathIfValid()
        }
        piSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickPiSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Pi Sessions Directory"
        panel.message = "Choose the Pi sessions folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !piSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (piSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            piSessionsPath = url.path
            validatePiSessionsPath()
            commitPiSessionsPathIfValid()
        }
    }
}
