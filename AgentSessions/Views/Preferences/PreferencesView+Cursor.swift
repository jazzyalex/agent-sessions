import SwiftUI
import AppKit

extension PreferencesView {
    var cursorTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cursor").font(.title2).fontWeight(.semibold)

            if !cursorAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General → Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Cursor CLI Binary")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Binary Source") {
                        Picker("", selection: Binding(
                            get: { cursorSettings.binaryPath.isEmpty ? 0 : 1 },
                            set: { idx in
                                if idx == 0 {
                                    cursorSettings.setBinaryPath("")
                                    scheduleCursorProbe()
                                } else {
                                    pickCursorBinary()
                                }
                            }
                        )) {
                            Text("Auto").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .help("Use the auto-detected Cursor CLI or supply a custom path")
                    }

                    if cursorSettings.binaryPath.isEmpty {
                        HStack {
                            Text("Detected:").font(.caption)
                            Text(cursorVersionString ?? "unknown").font(.caption).monospaced()
                        }
                        if let path = cursorResolvedPath {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }

                        if cursorProbeState == .failure && cursorVersionString == nil {
                            PreferenceCallout {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cursor CLI not found")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("Install Cursor Agent from cursor.com/download and ensure `cursor` is on PATH.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Check Version") { probeCursor() }
                                .buttonStyle(.bordered)
                                .help("Query the detected Cursor CLI for its version")
                            Button("Copy Path") {
                                if let p = cursorResolvedPath {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p, forType: .string)
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the detected Cursor CLI path to clipboard")
                            .disabled(cursorResolvedPath == nil)
                            Button("Reveal") {
                                if let p = cursorResolvedPath {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Reveal the detected Cursor CLI binary in Finder")
                            .disabled(cursorResolvedPath == nil)
                        }
                    } else {
                        HStack(spacing: 10) {
                            TextField("/path/to/agent", text: Binding(get: { cursorSettings.binaryPath }, set: { cursorSettings.setBinaryPath($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { scheduleCursorProbe() }
                                .onChange(of: cursorSettings.binaryPath) { _, _ in scheduleCursorProbe() }
                                .help("Enter the full path to a custom Cursor CLI binary")
                            Button("Choose…", action: pickCursorBinary)
                                .buttonStyle(.borderedProminent)
                                .help("Select the Cursor CLI binary from the filesystem")
                        }
                        if !cursorSettings.binaryPath.isEmpty, cursorProbeState == .failure {
                            Text("Invalid Cursor binary path.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .cursor)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Storage Root") {
                        Text("~/.cursor")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Transcripts") {
                        Text("~/.cursor/projects/*/agent-transcripts/")
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Chat Metadata") {
                        Text("~/.cursor/chats/*/*/store.db")
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }

                sectionHeader("Custom Root Override")
                VStack(alignment: .leading, spacing: 6) {
                    @AppStorage(PreferencesKey.Paths.cursorSessionsRootOverride) var cursorRootOverride: String = ""

                    TextField("Custom root (leave empty for default)", text: $cursorRootOverride)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Text("Override the default ~/.cursor path. Most users should leave this empty.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!cursorAgentEnabled)

            Spacer()
        }
        .onAppear {
            scheduleCursorProbe()
        }
    }

    func pickCursorBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Cursor CLI Binary"
        panel.message = "Choose the agent executable file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            cursorSettings.setBinaryPath(url.path)
            scheduleCursorProbe()
        }
    }
}
