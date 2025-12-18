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

	    var geminiCLITab: some View {
	        VStack(alignment: .leading, spacing: 18) {
	            Text("Gemini CLI").font(.title2).fontWeight(.semibold)

	            if !geminiAgentEnabled {
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
                        get: { geminiSettings.binaryOverride.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                geminiSettings.setBinaryOverride("")
                                scheduleGeminiProbe()
                            } else {
                                // Custom: open file picker
                                pickGeminiBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Use the auto-detected Gemini CLI or supply a custom path")
                }

                // Auto row (detected path + version + actions)
                if geminiSettings.binaryOverride.isEmpty {
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(geminiVersionString ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = geminiResolvedPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if geminiProbeState == .failure && geminiVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Gemini CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Binary name: gemini · Install via npm: npm install -g @google/gemini-cli")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeGemini() }
                            .buttonStyle(.bordered)
                            .help("Query the detected Gemini CLI for its version")
                        Button("Copy Path") {
                            if let p = geminiResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Gemini CLI path to clipboard")
                        .disabled(geminiResolvedPath == nil)
                        Button("Reveal") {
                            if let p = geminiResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Gemini CLI binary in Finder")
                        .disabled(geminiResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/gemini", text: Binding(get: { geminiSettings.binaryOverride }, set: { geminiSettings.setBinaryOverride($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleGeminiProbe() }
                            .onChange(of: geminiSettings.binaryOverride) { _, _ in scheduleGeminiProbe() }
                            .help("Enter the full path to a custom Gemini CLI binary")
                        Button("Choose…", action: pickGeminiBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Gemini CLI binary from the filesystem")
                        Button("Clear") {
                            geminiSettings.setBinaryOverride("")
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                }
            }

            // Sessions Directory (Gemini)
            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $geminiSessionsPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateGeminiSessionsPath()
                            commitGeminiSessionsPathIfValid()
                        }
                        .onChange(of: geminiSessionsPath) { _, _ in
                            validateGeminiSessionsPath()
                            geminiSessionsPathDebounce?.cancel()
                            let work = DispatchWorkItem { commitGeminiSessionsPathIfValid() }
                            geminiSessionsPathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the Gemini sessions directory. Leave blank to use the default location")

                    Button(action: pickGeminiSessionsFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory to store Gemini session logs")
                }

                if !geminiSessionsPathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

	                Text("Default: ~/.gemini")
	                    .font(.system(.caption, design: .monospaced))
	                    .foregroundStyle(.secondary)
	            }
	            }
	            .disabled(!geminiAgentEnabled)

	            Spacer()
	        }
	    }

    // MARK: - Gemini Pickers

    func pickGeminiSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Gemini Sessions Directory"
        panel.message = "Choose a folder where Gemini session logs are stored"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        // Start at current override or default
        if !geminiSessionsPath.isEmpty {
            let expanded = (geminiSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".gemini")
        }

        if panel.runModal() == .OK, let url = panel.url {
            geminiSessionsPath = url.path
            validateGeminiSessionsPath()
            commitGeminiSessionsPathIfValid()
        }
    }

    // MARK: - Gemini Path Validation

    func validateGeminiSessionsPath() {
        guard !geminiSessionsPath.isEmpty else {
            geminiSessionsPathValid = true
            return
        }
        let expanded = (geminiSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        geminiSessionsPathValid = exists && isDir.boolValue
    }

    func commitGeminiSessionsPathIfValid() {
        guard geminiSessionsPathValid else { return }
        // The @AppStorage binding will automatically persist the value
        // GeminiSessionIndexer listens to UserDefaults changes and triggers its own refresh
    }

}
