import SwiftUI

/// Main Git Inspector view that combines historical, current, and safety sections
struct GitInspectorView: View {
    let session: Session
    let onResume: (Session) -> Void

    @State private var historicalContext: HistoricalGitContext?
    @State private var currentStatus: CurrentGitStatus?
    @State private var safetyCheck: GitSafetyCheck?
    @State private var isLoadingCurrent = false
    @State private var errorMessage: String?
    @State private var expandHistorical: Bool = true
    @State private var expandSafety: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    headerView
                    contentView
                }
                .padding(20)
            }
            Divider()
            // Footer actions: always visible; outside scrolling content
            VStack(spacing: 12) {
                ButtonActionsView(
                    session: session,
                    currentStatus: currentStatus,
                    safetyCheck: safetyCheck,
                    onRefresh: refreshStatus,
                    onResume: { onResume(session) }
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadData() }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(2)

            HStack(spacing: 10) {
                // Agent badge
                Text(session.source.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .cornerRadius(4)

                Text("•")
                    .foregroundStyle(.secondary)

                Text("\(session.messageCount) messages")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Text("•")
                    .foregroundStyle(.secondary)

                Text(session.modifiedRelative)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Divider()
        }
    }

    // MARK: - Content Views
    @ViewBuilder
    private var contentView: some View {
        // Show whichever data is available, prioritizing historical+current combined when possible
        if let historical = historicalContext {
            // Snapshot (collapsible by default when identical to current)
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(isExpanded: $expandHistorical) {
                    HistoricalSection(context: historical)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill").foregroundStyle(.blue)
                        Text("SNAPSHOT AT SESSION START").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        if let c = currentStatus, isIdentical(historical: historical, current: c) {
                            Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("Same").font(.system(size: 11)).foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(0)

            // Current Section
            if isLoadingCurrent {
                loadingView
            } else if let current = currentStatus {
                CurrentSection(status: current, onRefresh: refreshStatus)
                // Safety (collapsible when status is safe)
                if let safety = safetyCheck {
                    VStack(alignment: .leading, spacing: 8) {
                        DisclosureGroup(isExpanded: $expandSafety) {
                            SafetySection(check: safety)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                                Text("RESUME SAFETY CHECK").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                if safety.status == .safe { Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("Safe").font(.system(size: 11)).foregroundStyle(.green) }
                            }
                        }
                    }
                }
            } else {
                currentUnavailableView
            }

        } else if isLoadingCurrent {
            loadingView
        } else if let current = currentStatus {
            // Current-only view (no historical metadata)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(.secondary)
                    Text("CURRENT STATE (live)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Checked " + current.relativeTimeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                CurrentSection(status: current, onRefresh: refreshStatus)
                Divider()
                Text("Historical metadata was not captured in this session.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        } else {
            noGitDataView
        }
    }

    private var comparisonDivider: some View {
        HStack {
            Spacer()
            Image(systemName: "arrow.down")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Loading current git status...")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var currentUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text("Current State Unavailable")
                .font(.system(size: 15, weight: .semibold))

            Text("Unable to query git status. The repository may no longer exist or is not accessible.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var noGitDataView: some View {
        VStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            Text("Git Information Not Available")
                .font(.system(size: 15, weight: .semibold))

            Text("This session doesn't contain git metadata.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var nonCodexView: some View {
        VStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            Text("Git Inspector: Codex Only")
                .font(.system(size: 15, weight: .semibold))

            Text("Git Context Inspector is currently only available for Codex sessions. Support for other agents coming soon.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.red)

            Text("Error")
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Data Loading
    private func loadData() async {
        // Extract historical context (instant, from session file)
        historicalContext = session.historicalGitContext

        // Load current status (async, from git CLI)
        await loadCurrentStatus()
    }

    private func loadCurrentStatus() async {
        guard let cwd = session.cwd else {
            return
        }

        isLoadingCurrent = true
        defer { isLoadingCurrent = false }

        currentStatus = await GitStatusCache.shared.getStatus(for: cwd)

        // Compute safety check if we have both historical and current
        if let historical = historicalContext, let current = currentStatus {
            safetyCheck = GitSafetyAnalyzer.analyze(historical: historical, current: current)
            // Configure collapsible defaults on main thread
            await MainActor.run {
                // Snapshot collapsed if identical; else expanded
                expandHistorical = !isIdentical(historical: historical, current: current)
                // Safety expanded when not safe
                expandSafety = (safetyCheck?.status ?? .unknown) != .safe
            }
        } else {
            await MainActor.run {
                // Without both, prefer expanded current and collapsed others
                expandHistorical = false
                expandSafety = false
            }
        }
    }

    // MARK: - Helpers
    private func isIdentical(historical: HistoricalGitContext, current: CurrentGitStatus) -> Bool {
        if let hb = historical.branch, let cb = current.branch, hb == cb,
           let hc = historical.commitHash, let cc = current.commitHash, hc == cc,
           current.isDirty == false {
            return true
        }
        return false
    }

    private func isHistoricalExpandedDefault(historical: HistoricalGitContext, current: CurrentGitStatus?) -> Bool {
        guard let c = current else { return true }
        return !isIdentical(historical: historical, current: c)
    }

    private func refreshStatus() async {
        guard let cwd = session.cwd else {
            return
        }

        // Invalidate cache and re-query
        await GitStatusCache.shared.invalidate(for: cwd)
        await loadCurrentStatus()
    }
}

#Preview {
    GitInspectorView(
        session: Session(
            id: "test-session",
            source: .codex,
            startTime: Date().addingTimeInterval(-7200),
            endTime: Date(),
            model: "claude-sonnet-4",
            filePath: "/test/session.jsonl",
            eventCount: 529,
            events: [
                SessionEvent(
                    id: "1",
                    timestamp: Date().addingTimeInterval(-7200),
                    kind: .meta,
                    role: nil,
                    text: nil,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: nil,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: """
                    {"payload": {"git": {"branch": "feature/perf-improvements", "commit_hash": "2f8a9c1d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b", "is_clean": true}}}
                    """
                )
            ]
        ),
        onResume: { _ in }
    )
}
