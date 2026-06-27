import SwiftUI
import AppKit

extension PreferencesView {

	    var codexCLITab: some View {
	        VStack(alignment: .leading, spacing: 24) {
	            Text("Codex CLI")
	                .font(.title2)
	                .fontWeight(.semibold)

	            if !codexAgentEnabled {
	                PreferenceCallout {
	                    Text("This agent is disabled in General → Active CLI agents.")
	                        .font(.caption)
	                        .foregroundStyle(.secondary)
	                }
	            }

	            Group {
	            sectionHeader("Codex CLI Binary")
	            VStack(alignment: .leading, spacing: 12) {
	                labeledRow("Binary Source") {
	                    Picker("", selection: Binding(
	                        get: { codexBinaryOverride.isEmpty ? 0 : 1 },
	                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                codexBinaryOverride = ""
                                validateBinaryOverride()
                                resumeSettings.setBinaryOverride("")
                                scheduleCodexProbe()
                            } else {
                                // Custom: open file picker
                                pickCodexBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Choose the Codex binary automatically or specify a custom executable")
                }

                if codexBinaryOverride.isEmpty {
                    // Auto mode: show detected binary
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(probeVersion?.description ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = resolvedCodexPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if probeState == .failure && probeVersion == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Codex CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install via npm: npm install -g @openai/codex-cli")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeCodex() }
                            .buttonStyle(.bordered)
                            .help("Query the currently detected Codex binary for its version")
                        Button(agentUpdateButtonTitle(for: .codex)) { runAgentUpdateFlow(for: .codex) }
                            .buttonStyle(.bordered)
                            .help("Check for a newer Codex CLI version and optionally update it")
                            .disabled(isAgentUpdateBusy(.codex))
                        Button("Copy Path") {
                            if let p = resolvedCodexPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Codex binary path to clipboard")
                        .disabled(resolvedCodexPath == nil)
                        Button("Reveal") {
                            if let p = resolvedCodexPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Codex binary in Finder")
                        .disabled(resolvedCodexPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/codex", text: $codexBinaryOverride)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { validateBinaryOverride(); commitCodexBinaryIfValid() }
                            .onChange(of: codexBinaryOverride) { _, _ in validateBinaryOverride(); commitCodexBinaryIfValid() }
                            .help("Enter the full path to a custom Codex binary")
                        Button("Choose…", action: pickCodexBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Codex binary from the filesystem")
                        Button("Clear") {
                            codexBinaryOverride = ""
                            validateBinaryOverride()
                            resumeSettings.setBinaryOverride("")
                            scheduleCodexProbe()
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                    if !codexBinaryValid {
                        Label("Must be an executable file", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $codexPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateCodexPath()
                            commitCodexPathIfValid()
                        }
                        .onChange(of: codexPath) { _, _ in
                            validateCodexPath()
                            // Debounce commit on typing to avoid thrash
                            codexPathDebounce?.cancel()
                            let work = DispatchWorkItem { commitCodexPathIfValid() }
                            codexPathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the Codex sessions directory. Leave blank to use the default location")

                    Button(action: pickCodexFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory to store Codex session logs")
                }

                if !codexPathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

	                Text("Default: $CODEX_HOME/sessions or ~/.codex/sessions")
	                    .font(.system(.caption, design: .monospaced))
	                    .foregroundStyle(.secondary)
	            }
	            }
	            .disabled(!codexAgentEnabled)
	        }
	    }

	    var claudeResumeTab: some View {
	        VStack(alignment: .leading, spacing: 18) {
	            Text("Claude Code").font(.title2).fontWeight(.semibold)

	            if !claudeAgentEnabled {
	                PreferenceCallout {
	                    Text("This agent is disabled in General → Active CLI agents.")
	                        .font(.caption)
	                        .foregroundStyle(.secondary)
	                }
	            }

	            Group {
	            // Binary Source
	            VStack(alignment: .leading, spacing: 10) {
                // Binary source segmented: Auto | Custom
                labeledRow("Binary Source") {
                    Picker("", selection: Binding(
                        get: { claudeSettings.binaryPath.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                claudeSettings.setBinaryPath("")
                                scheduleClaudeProbe()
                            } else {
                                // Custom: open file picker
                                pickClaudeBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Use the auto-detected Claude CLI or supply a custom path")
                }

                // Auto row (detected path + version + actions)
                if claudeSettings.binaryPath.isEmpty {
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(claudeVersionString ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = claudeResolvedPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if claudeProbeState == .failure && claudeVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claude CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Download from claude.ai/download or install via npm: npm install -g @anthropic/claude-cli")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeClaude() }
                            .buttonStyle(.bordered)
                            .help("Query the detected Claude CLI for its version")
                        Button(agentUpdateButtonTitle(for: .claude)) { runAgentUpdateFlow(for: .claude) }
                            .buttonStyle(.bordered)
                            .help("Check package-managed Claude installs, or run Claude Code's built-in updater for ~/.local installs")
                            .disabled(isAgentUpdateBusy(.claude))
                        Button("Copy Path") {
                            if let p = claudeResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Claude CLI path to clipboard")
                        .disabled(claudeResolvedPath == nil)
                        Button("Reveal") {
                            if let p = claudeResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Claude CLI binary in Finder")
                        .disabled(claudeResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/claude", text: Binding(get: { claudeSettings.binaryPath }, set: { claudeSettings.setBinaryPath($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleClaudeProbe() }
                            .onChange(of: claudeSettings.binaryPath) { _, _ in scheduleClaudeProbe() }
                            .help("Enter the full path to a custom Claude CLI binary")
                        Button("Choose…", action: pickClaudeBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Claude CLI binary from the filesystem")
                        Button("Clear") {
                            claudeSettings.setBinaryPath("")
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                }
            }

            // Sessions Directory (Claude)
            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $claudePath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateClaudePath()
                            commitClaudePathIfValid()
                        }
                        .onChange(of: claudePath) { _, _ in
                            validateClaudePath()
                            claudePathDebounce?.cancel()
                            let work = DispatchWorkItem { commitClaudePathIfValid() }
                            claudePathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the Claude sessions directory. Leave blank to use the default location")

                    Button(action: pickClaudeFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory to store Claude session logs")
                }

                if !claudePathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Default: ~/.claude")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Usage Tracking moved to Unified Window tab.

	            // Probe cleanup controls moved to Usage Tracking → Usage Terminal Probes
	            }
	            .disabled(!claudeAgentEnabled)
	        }
	    }

	    var antigravityCLITab: some View {
	        VStack(alignment: .leading, spacing: 18) {
	            Text("Antigravity CLI").font(.title2).fontWeight(.semibold)

	            if !antigravityAgentEnabled {
	                PreferenceCallout {
	                    Text("This agent is disabled in General → Active CLI agents.")
	                        .font(.caption)
	                        .foregroundStyle(.secondary)
	                }
	            }

	            Group {
	            // Binary Source
	            VStack(alignment: .leading, spacing: 10) {
                // Binary source segmented: Auto | Custom
                labeledRow("Binary Source") {
                    Picker("", selection: Binding(
                        get: { antigravitySettings.binaryOverride.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                antigravitySettings.setBinaryOverride("")
                                scheduleAntigravityProbe()
                            } else {
                                // Custom: open file picker
                                pickAntigravityBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Use the auto-detected Antigravity CLI or supply a custom path")
                }

                // Auto row (detected path + version + actions)
                if antigravitySettings.binaryOverride.isEmpty {
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(antigravityVersionString ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = antigravityResolvedPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if antigravityProbeState == .failure && antigravityVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Antigravity CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Binary name: agy · Install with the Antigravity CLI install script")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeAntigravity() }
                            .buttonStyle(.bordered)
                            .help("Query the detected Antigravity CLI for its version")
                        Button(agentUpdateButtonTitle(for: .antigravity)) { runAgentUpdateFlow(for: .antigravity) }
                            .buttonStyle(.bordered)
                            .help("Check for a newer Antigravity CLI version and optionally update it")
                            .disabled(isAgentUpdateBusy(.antigravity))
                        Button("Copy Path") {
                            if let p = antigravityResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Antigravity CLI path to clipboard")
                        .disabled(antigravityResolvedPath == nil)
                        Button("Reveal") {
                            if let p = antigravityResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Antigravity CLI binary in Finder")
                        .disabled(antigravityResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/agy", text: Binding(get: { antigravitySettings.binaryOverride }, set: { antigravitySettings.setBinaryOverride($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleAntigravityProbe() }
                            .onChange(of: antigravitySettings.binaryOverride) { _, _ in scheduleAntigravityProbe() }
                            .help("Enter the full path to a custom Antigravity CLI binary")
                        Button("Choose…", action: pickAntigravityBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Antigravity CLI binary from the filesystem")
                        Button("Clear") {
                            antigravitySettings.setBinaryOverride("")
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                }
            }

            // Sessions Directory (Antigravity)
            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $antigravitySessionsPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateAntigravitySessionsPath()
                            commitAntigravitySessionsPathIfValid()
                        }
                        .onChange(of: antigravitySessionsPath) { _, _ in
                            validateAntigravitySessionsPath()
                            antigravitySessionsPathDebounce?.cancel()
                            let work = DispatchWorkItem { commitAntigravitySessionsPathIfValid() }
                            antigravitySessionsPathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the Antigravity artifact directory. Leave blank to use the default location")

                    Button(action: pickAntigravitySessionsFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory that stores Antigravity artifacts")
                }

                if !antigravitySessionsPathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

	                Text("Default: ~/.gemini/antigravity/brain and ~/.gemini/antigravity-cli/brain")
	                    .font(.system(.caption, design: .monospaced))
	                    .foregroundStyle(.secondary)
	            }
	            }
	            .disabled(!antigravityAgentEnabled)

	            Spacer()
	        }
	    }

    // MARK: - Antigravity Pickers

    func pickAntigravitySessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Antigravity Artifact Directory"
        panel.message = "Choose the folder where Antigravity brain artifacts are stored"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        // Start at current override or default
        if !antigravitySessionsPath.isEmpty {
            let expanded = (antigravitySessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".gemini/antigravity/brain")
        }

        if panel.runModal() == .OK, let url = panel.url {
            antigravitySessionsPath = url.path
            validateAntigravitySessionsPath()
            commitAntigravitySessionsPathIfValid()
        }
    }

    // MARK: - Antigravity Path Validation

    func validateAntigravitySessionsPath() {
        guard !antigravitySessionsPath.isEmpty else {
            antigravitySessionsPathValid = true
            return
        }
        let expanded = (antigravitySessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        antigravitySessionsPathValid = exists && isDir.boolValue
    }

    func commitAntigravitySessionsPathIfValid() {
        guard antigravitySessionsPathValid else { return }
        // The @AppStorage binding will automatically persist the value
        // Antigravity indexer listens to UserDefaults changes and triggers its own refresh.
    }

}
