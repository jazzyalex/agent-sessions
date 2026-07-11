import SwiftUI
import AppKit

/// Status pill shown when a provider's usage auth needs attention. Every surface
/// (footer strip, menu-bar dropdown, Cockpit HUD meter) renders one of these and
/// routes its "Fix…" button to a single guided dialog (`AuthFixView`) that
/// explains the problem and walks through the fixes in order.
///
/// Modes:
/// - `chip`   — single-line pill (`⚠ Claude auth expired  Fix…`) used in the
///   footer and the HUD meter in place of the meter.
/// - `compact`— one quiet line (icon + headline + Fix…).
/// - full     — icon + headline + detail + Fix….
struct AuthRemediationBanner: View {
    let status: UsageAuthStatus
    var compact: Bool = false
    var chip: Bool = false
    /// Nested inside a strip that already provides padding/material — suppress ours.
    var embedded: Bool = false

    var body: some View {
        if chip {
            chipBody
        } else if compact {
            compactBody
        } else {
            fullBody
        }
    }

    // MARK: - Chip mode

    private var chipBody: some View {
        HStack(spacing: 6) {
            Image(systemName: severityIcon.name)
                .foregroundStyle(severityIcon.color)
                .font(.caption2)
            Text(status.chipLabel)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(headlineColor)
                .lineLimit(1)
                .fixedSize()
            fixButton
        }
        .padding(.horizontal, embedded ? 0 : 8)
        .padding(.vertical, 3)
    }

    // MARK: - Full mode

    private var fullBody: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severityIcon.name)
                .foregroundStyle(severityIcon.color)
                .font(.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.headline)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(headlineColor)
                Text(status.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            fixButton
        }
        .padding(.horizontal, embedded ? 0 : 10)
        .padding(.vertical, 8)
        .background(embedded ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.thinMaterial))
    }

    // MARK: - Compact mode

    private var compactBody: some View {
        HStack(spacing: 6) {
            Image(systemName: severityIcon.name)
                .foregroundStyle(severityIcon.color)
                .font(.caption2)
            Text(status.headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            fixButton
        }
        .padding(.horizontal, embedded ? 0 : 10)
        .padding(.vertical, 4)
    }

    // MARK: - Fix button

    /// One guided dialog for every surface, instead of a bare Copy/Install control.
    private var fixButton: some View {
        Button("Fix…") { AuthFixWindowController.shared.show(status: status) }
            .buttonStyle(.borderless)
            .font(.caption)
            .fontWeight(.semibold)
    }

    // MARK: - Severity styling

    private var severityIcon: (name: String, color: Color) {
        switch status.state {
        case .signedOut:
            return ("exclamationmark.triangle.fill", .red)
        case .expired:
            return ("clock.badge.exclamationmark", .orange)
        case .cliNotInstalled:
            return ("bolt.horizontal.circle", .secondary)
        default:
            return ("exclamationmark.triangle.fill", .secondary)
        }
    }

    private var headlineColor: Color {
        switch status.state {
        case .signedOut: return .red
        case .expired: return .orange
        default: return .primary
        }
    }
}

// MARK: - Fix dialog window

/// Presents the shared `AuthFixView` in a small panel, reachable from both
/// SwiftUI surfaces and the AppKit menu-bar dropdown.
@MainActor
final class AuthFixWindowController {
    static let shared = AuthFixWindowController()
    private var window: NSWindow?
    private var hosting: NSHostingView<AuthFixView>?

    func show(status: UsageAuthStatus) {
        let root = AuthFixView(status: status, onClose: { [weak self] in self?.window?.close() })
        if let win = window, let hv = hosting {
            hv.rootView = root
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hv = NSHostingView(rootView: root)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Fix Usage Tracking"
        win.contentView = hv
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        hosting = hv
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Fix dialog

/// Guided remediation: explains what's wrong and walks through the fixes in
/// order (re-authenticate → Web API fallback → CLI probe → recheck). Adapts to
/// the provider and auth state.
struct AuthFixView: View {
    let status: UsageAuthStatus
    var onClose: () -> Void

    @ObservedObject private var claude = ClaudeUsageModel.shared
    @AppStorage(PreferencesKey.claudeWebApiEnabled) private var webApiEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeTmuxAutoFallbackOptIn) private var cliProbeEnabled: Bool = false
    @State private var copied = false
    @State private var refreshStatus: String?

    private var isClaude: Bool { status.providerName != "Codex" }
    private var loginCommand: String? {
        if case .showCommand(let c) = status.remediation { return c }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: severityIcon.name)
                    .font(.title2)
                    .foregroundStyle(severityIcon.color)
                Text("Fix \(providerName) usage")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What's happening")
                            .font(.subheadline).fontWeight(.semibold)
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    Text("Try these, in order")
                        .font(.subheadline).fontWeight(.semibold)

                    if let cmd = loginCommand {
                        stepRow("A", "Re-authenticate", "Run this in Terminal — usage returns automatically once you're signed in. This is almost always all that's needed.") {
                            HStack(spacing: 8) {
                                Text(cmd)
                                    .font(.system(.callout, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(5)
                                Button(copied ? "Copied ✓" : "Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    if isClaude {
                        stepRow("B", "Use the Web API fallback", "If the CLI login keeps failing, Agent Sessions can read usage from your claude.ai browser session instead. Needs Full Disk Access on macOS 14+.") {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Enable Web API fallback", isOn: $webApiEnabled)
                                    .onChange(of: webApiEnabled) { _, on in if on { requestRefetch() } }
                                Button("Open Full Disk Access…") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.link).font(.caption)
                            }
                        }

                        stepRow("C", "Allow the CLI probe fallback", "Last resort: run the Claude CLI in the background to read usage. Off by default because the interactive CLI can pop a browser sign-in.") {
                            Toggle("Allow CLI probe fallback", isOn: $cliProbeEnabled)
                                .onChange(of: cliProbeEnabled) { _, on in if on { requestRefetch() } }
                        }
                    }

                    stepRow(isClaude ? "D" : "B", "Recheck now", "After trying the above, re-run the usage fetch to confirm.") {
                        HStack(spacing: 10) {
                            Button("Refresh now") { recheck() }
                                .buttonStyle(.bordered)
                            if let s = refreshStatus {
                                Text(s).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if status.state == .cliNotInstalled {
                        stepRow("i", "No \(providerName) CLI?", "Install it so Agent Sessions can read usage directly.") {
                            Button("Install \(providerName) CLI…") { openInstall() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Divider().padding(.vertical, 10)
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 500)
    }

    // MARK: - Step row

    @ViewBuilder
    private func stepRow<Content: View>(_ badge: String, _ title: String, _ desc: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(badge)
                .font(.caption2).fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout).fontWeight(.semibold)
                Text(desc).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    // MARK: - Actions

    private func recheck() {
        refreshStatus = "Checking…"
        let claudeCtx = isClaude
        if claudeCtx { ClaudeUsageModel.shared.refreshNow() } else { CodexUsageModel.shared.refreshNow() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            let verdict = claudeCtx ? ClaudeUsageModel.shared.authStatus : CodexUsageModel.shared.authStatus
            refreshStatus = (verdict?.state.isAlarming ?? false) ? "Still unavailable — try step A." : "Updated ✓"
        }
    }

    private func requestRefetch() {
        NotificationCenter.default.post(name: .claudeUsageRefreshRequested, object: nil)
    }

    private func openInstall() {
        let url: URL?
        switch status.remediation {
        case .openURL(let u): url = u
        case .noCLILadder(_, let docs): url = docs
        default: url = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Copy

    private var providerName: String { status.providerName.isEmpty ? "Claude" : status.providerName }

    private var explanation: String {
        switch status.state {
        case .expired:
            return "Agent Sessions reads your \(providerName) usage using the \(providerName) CLI's saved login. That login has expired, so your account is now rejecting usage requests — retrying on its own won't recover it. Re-authenticate to restore it."
        case .signedOut:
            return "You're signed out of the \(providerName) CLI, so Agent Sessions has no session to read usage from. Sign back in to restore it."
        case .cliNotInstalled:
            return "The \(providerName) CLI isn't installed, so there's no signed-in session to read usage from. Install it, or use the Web API fallback below."
        default:
            return "\(providerName) usage is temporarily unavailable."
        }
    }

    private var severityIcon: (name: String, color: Color) {
        switch status.state {
        case .signedOut: return ("exclamationmark.triangle.fill", .red)
        case .expired: return ("clock.badge.exclamationmark", .orange)
        case .cliNotInstalled: return ("bolt.horizontal.circle", .secondary)
        default: return ("exclamationmark.triangle.fill", .orange)
        }
    }
}

#if DEBUG
struct AuthRemediationBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuthRemediationBanner(status: .make(provider: .claude, state: .expired), chip: true)
            AuthRemediationBanner(status: .make(provider: .claude, state: .signedOut), compact: true)
            AuthRemediationBanner(status: .make(provider: .claude, state: .cliNotInstalled))
            AuthFixView(status: .make(provider: .claude, state: .expired), onClose: {})
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
