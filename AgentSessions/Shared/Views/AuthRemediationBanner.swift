import SwiftUI
import AppKit

/// Compact horizontal banner rendered inside a usage strip when the CLI auth
/// status needs user remediation (signed out, expired, CLI missing, etc).
///
/// Two modes:
/// - `compact == false` ("full"): replaces the meters entirely when there's
///   no live usage data to show alongside it. Shows icon + headline + detail
///   + remediation control.
/// - `compact == true`: a single quiet line shown under/alongside cached
///   meters. Icon + headline only (no detail), smaller vertical padding.
struct AuthRemediationBanner: View {
    let status: UsageAuthStatus
    var compact: Bool = false
    /// When true, this banner is nested inside a usage strip that already
    /// provides horizontal padding and a material background — suppress our
    /// own to avoid double padding / double material.
    var embedded: Bool = false

    /// Drives the no-CLI ladder help alert (rung 1 Web API mode, rung 2 install).
    @State private var showNoCLIHelp = false

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
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

            remediationControl
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

            remediationControl
        }
        .padding(.horizontal, embedded ? 0 : 10)
        .padding(.vertical, 4)
    }

    // MARK: - Remediation control

    @ViewBuilder
    private var remediationControl: some View {
        switch status.remediation {
        case .showCommand(let cmd):
            CommandCopyControl(command: cmd)
        case .openURL(let url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Install…", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        case .noCLILadder(let installCommand, let docsURL):
            // Zero-install-first: rung 1 enables the shipped Web API mode; rung 2
            // guides the CLI install. AS only toggles a pref / copies a command —
            // it never runs an installer or a login. Mirrors the tmux-help alert.
            Button("How to fix…") { showNoCLIHelp = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .alert("Fix runway without the CLI", isPresented: $showNoCLIHelp) {
                    Button("Enable Web API mode") {
                        UserDefaults.standard.set(true, forKey: PreferencesKey.claudeWebApiEnabled)
                    }
                    Button("Copy CLI install command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    }
                    Button("Open install guide") { NSWorkspace.shared.open(docsURL) }
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Sign in at claude.ai, then enable Web API mode — no CLI needed (reads the Safari session cookie; may need Full Disk Access on macOS 14+).\n\nOr install the Claude CLI:\n\n  \(installCommand)")
                }
        case .none:
            EmptyView()
        }
    }

    // MARK: - Severity styling

    private var severityIcon: (name: String, color: Color) {
        switch status.state {
        case .signedOut:
            return ("exclamationmark.triangle.fill", .red)
        case .expired:
            // Introduced in SF Symbols 4 (macOS 13+); deployment target is
            // macOS 14, so this is safe to reference directly.
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

/// Monospaced command chip + Copy button used by `.showCommand` remediations.
private struct CommandCopyControl: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)

            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

#if DEBUG
struct AuthRemediationBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuthRemediationBanner(
                status: .make(provider: .claude, state: .signedOut),
                compact: false
            )
            .frame(width: 420)

            AuthRemediationBanner(
                status: .make(provider: .claude, state: .expired),
                compact: false
            )
            .frame(width: 420)

            AuthRemediationBanner(
                status: .make(provider: .claude, state: .cliNotInstalled),
                compact: false
            )
            .frame(width: 420)

            // No-CLI ladder (Desktop-only): "How to fix…" → Web API / install alert.
            AuthRemediationBanner(
                status: .make(provider: .claude, state: .expired, cliPresent: false),
                compact: false
            )
            .frame(width: 420)

            AuthRemediationBanner(
                status: .make(provider: .claude, state: .signedOut),
                compact: true
            )
            .frame(width: 420)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
