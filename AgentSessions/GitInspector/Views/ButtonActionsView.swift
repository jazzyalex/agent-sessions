import SwiftUI
import AppKit

/// Action buttons for the Git Inspector
struct ButtonActionsView: View {
    let session: Session
    let currentStatus: CurrentGitStatus?
    let safetyCheck: GitSafetyCheck?
    let onRefresh: () async -> Void
    let onResume: () -> Void

    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            openDirectoryButton
            refreshStatusButton
            resumeButton
            Spacer()
        }
    }

    // MARK: - Button 1: Open Directory
    private var openDirectoryButton: some View {
        Button(action: openDirectory) {
            HStack(spacing: 8) {
                Text("📂")
                Text("Open Directory")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
        .buttonStyle(ActionButtonStyle())
        .help("Open working directory in Finder")
    }

    private func openDirectory() {
        guard let cwd = session.cwd else { return }

        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
        } else {
            // Directory doesn't exist - show alert
            let alert = NSAlert()
            alert.messageText = "Directory Not Found"
            alert.informativeText = "The directory no longer exists:\n\(cwd)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Button 2: Refresh Status
    private var refreshStatusButton: some View {
        Button(action: { Task { await refresh() } }) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Text("🔄")
                }
                Text(isRefreshing ? "Refreshing..." : "Refresh Status")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
        .buttonStyle(ActionButtonStyle())
        .disabled(isRefreshing)
        .help("Re-query git for latest status")
    }

    private func refresh() async {
        isRefreshing = true
        await onRefresh()
        isRefreshing = false
    }

    // MARK: - Button 3: Resume
    private var resumeButton: some View {
        Button(action: handleResume) {
            HStack(spacing: 8) {
                Text("▶️")
                Text("Resume Session")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
        .buttonStyle(WarningButtonStyle())
        .help(resumeButtonHelp)
    }

    private var resumeButtonLabel: String {
        guard let safety = safetyCheck else {
            return "Resume"
        }

        switch safety.status {
        case .safe: return "Resume Session"
        case .caution, .warning: return "Resume Anyway"
        case .unknown: return "Resume"
        }
    }

    private var resumeButtonHelp: String {
        guard let safety = safetyCheck else {
            return "Resume this session"
        }

        switch safety.status {
        case .safe: return "Safe to resume"
        case .caution: return "Uncommitted changes detected - resume with caution"
        case .warning: return "Git state changed - resume with caution"
        case .unknown: return "Unable to verify safety"
        }
    }

    private func handleResume() {
        guard let safety = safetyCheck else {
            onResume()
            return
        }

        // Show confirmation for non-safe states
        if safety.shouldWarnBeforeResume {
            let alert = NSAlert()
            alert.messageText = safety.status == .caution ? "Uncommitted Changes Detected" : "Git State Changed"
            alert.informativeText = safety.recommendation
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Resume Anyway")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                onResume()
            }
        } else {
            onResume()
        }
    }

    // MARK: - Helper Methods
    private func openInTerminal(cwd: String, command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(cwd)' && \(command)"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)

            if let error = error {
                print("Failed to open Terminal: \(error)")
            }
        }
    }
}

// MARK: - Button Styles

/// Secondary button style for action buttons
struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(hex: "#f5f5f7") : .white)
            .foregroundColor(.primary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "#d1d1d6"), lineWidth: 1)
            )
    }
}

/// Warning button style for the Resume button
struct WarningButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(hex: "#e08600") : Color(hex: "#ff9500"))
            .foregroundColor(.white)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "#ff9500"), lineWidth: 1)
            )
    }
}

#Preview {
    ButtonActionsView(
        session: Session(
            id: "test",
            source: .codex,
            startTime: Date(),
            endTime: nil,
            model: "claude",
            filePath: "/test",
            eventCount: 0,
            events: []
        ),
        currentStatus: CurrentGitStatus(
            branch: "main",
            commitHash: "abc123",
            isDirty: true,
            dirtyFiles: []
        ),
        safetyCheck: GitSafetyCheck(
            status: .caution,
            checks: [],
            recommendation: "Test"
        ),
        onRefresh: {},
        onResume: {}
    )
    .padding()
    .frame(width: 600)
}
