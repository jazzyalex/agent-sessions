import SwiftUI
import AppKit

extension PreferencesView {
    var hermesCLITab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hermes").font(.title2).fontWeight(.semibold)

            if !hermesAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General → Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Hermes CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { hermesSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    hermesSettings.setBinaryPath("")
                                    scheduleHermesProbe()
                                } else {
                                    pickHermesBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }

                    if hermesSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(hermesVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = hermesResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if hermesProbeState == .failure && hermesVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Hermes CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install Hermes Agent and ensure `hermes` is on PATH.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Check Version") { probeHermes() }
                                .buttonStyle(.bordered)
                            Button("Copy Path") {
                                if let path = hermesResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(path, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(hermesResolvedPath == nil)
                            Button("Reveal") {
                                if let path = hermesResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(hermesResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/hermes", text: Binding(get: { hermesSettings.binaryPath }, set: { hermesSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleHermesProbe() }
                                .onChange(of: hermesSettings.binaryPath) { _, _ in scheduleHermesProbe() }
                            Button("Choose…", action: pickHermesBinary)
                                .buttonStyle(.borderedProminent)
                        }
                        if !hermesSettings.binaryPath.isEmpty, hermesProbeState == .failure {
                            Text("Invalid Hermes binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                sectionHeader("Sessions Folder")
                VStack(alignment: .leading, spacing: 8) {
                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("~/.hermes/sessions", text: $hermesSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit {
                                    validateHermesSessionsPath()
                                    commitHermesSessionsPathIfValid()
                                }
                                .onChange(of: hermesSessionsPath) { _, _ in
                                    hermesSessionsPathDebounce?.cancel()
                                    let work = DispatchWorkItem {
                                        validateHermesSessionsPath()
                                        commitHermesSessionsPathIfValid()
                                    }
                                    hermesSessionsPathDebounce = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                                }
                            Button("Choose…", action: pickHermesSessionsFolder)
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    if !hermesSessionsPathValid {
                        Text("Folder does not exist or is not a directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Default: ~/.hermes/sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!hermesAgentEnabled)

            Spacer()
        }
        .onAppear {
            scheduleHermesProbe()
        }
    }

    func probeHermes() {
        if hermesProbeState == .probing { return }
        hermesProbeState = .probing
        hermesVersionString = nil
        hermesResolvedPath = nil
        let override = hermesSettings.binaryPath.isEmpty ? nil : hermesSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = HermesCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.hermesVersionString = res.versionString
                    self.hermesResolvedPath = res.binaryURL.path
                    self.hermesProbeState = .success
                    self.hermesCLIAvailable = true
                case .failure:
                    self.hermesVersionString = nil
                    self.hermesResolvedPath = nil
                    self.hermesProbeState = .failure
                    self.hermesCLIAvailable = false
                }
            }
        }
    }

    func scheduleHermesProbe() {
        hermesProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeHermes() }
        hermesProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func pickHermesBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Hermes CLI Binary"
        panel.message = "Choose the hermes executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            hermesSettings.setBinaryPath(url.path)
            scheduleHermesProbe()
        }
    }

    func pickHermesSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Hermes Sessions Directory"
        panel.message = "Choose a folder where Hermes canonical session JSON files are stored"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !hermesSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (hermesSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/sessions")
        }
        if panel.runModal() == .OK, let url = panel.url {
            hermesSessionsPath = url.path
            validateHermesSessionsPath()
            commitHermesSessionsPathIfValid()
        }
    }

    func validateHermesSessionsPath() {
        guard !hermesSessionsPath.isEmpty else {
            hermesSessionsPathValid = true
            return
        }
        let expanded = (hermesSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        hermesSessionsPathValid = exists && isDir.boolValue
    }

    func commitHermesSessionsPathIfValid() {
        guard hermesSessionsPathValid else { return }
        let expanded = (hermesSessionsPath as NSString).expandingTildeInPath
        UserDefaults.standard.set(expanded, forKey: PreferencesKey.Paths.hermesSessionsRootOverride)
    }
}
