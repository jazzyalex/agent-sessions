import AppKit
import SwiftUI

/// Shared state between `QuotaStripController` and the SwiftUI strip.
@MainActor
final class QuotaStripModel: ObservableObject {
    @Published var expanded = false
    /// Minimal style: the collapsed shape is the notch only; hairlines replace the wings.
    /// Set by the controller (from `QuotaMeterNotchStyle`) before it computes any hit rect.
    @Published var minimal = false
    /// A popover from the expanded panel's toolbar is on screen; reported by the Quota Meter
    /// view, so the controller keeps the panel open without scanning windows.
    @Published var toolbarPopoverOpen = false
    /// Sticky runway ticks: when each session was last seen working. Not published (it is
    /// updated while the wings render); entries older than `tickHold` drop out.
    var lastWorkingAt: [String: Date] = [:]
    static let tickHold: TimeInterval = 30
    /// A session that stopped working within this window is "your turn" (owner 2026-10-19).
    static let yourTurnWindow: TimeInterval = 10 * 60
    /// The full Quota Meter is loaded while the strip is on screen (data stays current, as in
    /// the floating window); while collapsed it is hidden and its shimmer timer is paused.
    @Published var contentMounted = false
    /// Measured from the expanded Quota Meter content (notch row included). Remembered across
    /// rebuilds so the first open after a rebuild starts at the right size.
    @Published var expandedContentSize: CGSize = QuotaStripModel.lastExpandedContentSize {
        didSet { Self.lastExpandedContentSize = expandedContentSize }
    }
    private static var lastExpandedContentSize = CGSize(width: 440, height: 220)

    /// The tested size and hit-area rules (`QuotaStripSizing`, logic tests).
    let sizing: QuotaStripSizing
    var notchWidth: CGFloat { sizing.notchWidth }
    var notchHeight: CGFloat { sizing.notchHeight }
    var wingWidth: CGFloat { sizing.wingWidth }

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        sizing = QuotaStripSizing(notchWidth: notchWidth, notchHeight: notchHeight)
    }

    /// Width of the wings layout (wing · notch · wing, flares included), used by both styles.
    var wingsWidth: CGFloat { sizing.wingsWidth }

    /// In Minimal the collapsed shape is the notch alone, which is also the hover and click
    /// target; the menu bar beside the notch stays free.
    var collapsedSize: CGSize { sizing.collapsedSize(minimal: minimal) }

    var expandedSize: CGSize { sizing.expandedSize(content: expandedContentSize) }

    var shapeSize: CGSize { expanded ? expandedSize : collapsedSize }

    var panelSize: CGSize { sizing.panelSize(content: expandedContentSize) }

    /// Interactive rect in panel coordinates, origin top-left.
    var hitRect: CGRect { sizing.hitRect(expanded: expanded, minimal: minimal, content: expandedContentSize) }
}

private struct QuotaStripExpandedKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct QuotaStripPopoverReporterKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Bool) -> Void)? = nil
}

extension EnvironmentValues {
    /// Inside the menu bar strip: whether it is expanded. nil everywhere else.
    var quotaStripExpanded: Bool? {
        get { self[QuotaStripExpandedKey.self] }
        set { self[QuotaStripExpandedKey.self] = newValue }
    }

    /// Inside the menu bar strip: tells it whether a toolbar popover is on screen.
    var quotaStripPopoverReporter: (@MainActor (Bool) -> Void)? {
        get { self[QuotaStripPopoverReporterKey.self] }
        set { self[QuotaStripPopoverReporterKey.self] = newValue }
    }
}

private struct ExpandedContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct QuotaStripRootView<Expanded: View>: View {
    @ObservedObject var model: QuotaStripModel
    let expandedContent: Expanded

    /// Matches the HUD header's reveal animation (`revealChromeOnDemand`).
    static var contentResize: Animation { .easeInOut(duration: 0.2) }
    /// How long the panel waits before shrinking, so the shape's animation is not clipped.
    static var shrinkDelay: TimeInterval { 0.25 }

    var body: some View {
        let size = model.shapeSize
        let top = model.expanded ? NotchShape.openTop : NotchShape.closedTop
        let bottom = model.expanded ? NotchShape.openBottom : NotchShape.closedBottom
        ZStack(alignment: .top) {
            NotchShape(topRadius: top, bottomRadius: bottom)
                .fill(.black)
                .overlay {
                    NotchShape(topRadius: top, bottomRadius: bottom)
                        .stroke(Color.white.opacity(model.expanded ? 0.12 : 0), lineWidth: 0.5)
                }
                // Hides antialiasing seams against the screen edge.
                .overlay(alignment: .top) {
                    Rectangle().fill(.black).frame(height: 1).padding(.horizontal, top)
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(model.expanded ? 0.5 : 0), radius: 20, y: 10)

            if !model.expanded {
                // Wings centre in the menu bar row; Minimal hairlines sit at its bottom edge.
                QuotaStripWings(model: model)
                    .frame(width: model.wingsWidth, height: model.notchHeight,
                           alignment: model.minimal ? .top : .center)
                    .transition(.opacity)
            }

            // Loaded for as long as the strip is presented, so data is current on hover;
            // visible only while expanded.
            if model.contentMounted {
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notchHeight)
                    expandedContent
                        .environment(\.quotaStripExpanded, model.expanded)
                        .environment(\.quotaStripPopoverReporter, { [weak model] open in
                            model?.toolbarPopoverOpen = open
                        })
                }
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ExpandedContentSizeKey.self, value: proxy.size)
                })
                .opacity(model.expanded ? 1 : 0)
                .scaleEffect(model.expanded ? 1 : 0.98, anchor: .top)
                .animation(model.expanded ? .easeOut(duration: 0.22).delay(0.08) : .easeIn(duration: 0.1),
                           value: model.expanded)
                .allowsHitTesting(model.expanded)
            }
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
        .onPreferenceChange(ExpandedContentSizeKey.self) { size in
            guard size.width > 0, size.height > 0, size != model.expandedContentSize else { return }
            // While open, the black shape follows the content (e.g. the right-click toolbar
            // sliding in) with the same 0.2 s ease instead of jumping to the new size.
            if model.expanded {
                withAnimation(Self.contentResize) { model.expandedContentSize = size }
            } else {
                model.expandedContentSize = size
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Collapsed wings (mockup A): Codex on the left, Claude on the right. With one provider
/// visible, it takes both wings (5h left, weekly right). In the Minimal style the same cells
/// draw as two hairlines under the notch.
struct QuotaStripWings: View {
    @ObservedObject var model: QuotaStripModel
    @Environment(CodexActiveSessionsModel.self) private var activeCodex
    @ObservedObject private var probeCoordinator = ProbeCoordinator.shared
    @EnvironmentObject private var codexUsage: CodexUsageModel
    @EnvironmentObject private var claudeUsage: ClaudeUsageModel
    @AppStorage(PreferencesKey.quotaMeterHiddenProviders) private var hiddenRaw = QuotaMeterProviderVisibility.defaultRawValue
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled = true
    @AppStorage(PreferencesKey.usageDisplayMode) private var displayModeRaw = UsageDisplayMode.left.rawValue
    @AppStorage(PreferencesKey.usageLimitCockpitProjectionEnabled) private var projectionEnabled = true

    var body: some View {
        let cells = self.cells
        if model.minimal {
            // Hairlines sit on the bottom edge of the menu bar row beside the notch, where menu
            // bar items leave the pixels empty, so they never cover app windows below the bar.
            HStack(spacing: model.notchWidth + 12) {
                QuotaStripHairline(cell: cells.left?.cell, width: model.wingWidth - 12,
                                   label: Self.accessibilityLabel(cells.left))
                QuotaStripHairline(cell: cells.right?.cell, width: model.wingWidth - 12,
                                   label: Self.accessibilityLabel(cells.right))
            }
            .padding(.top, model.notchHeight - 4)
        } else {
            HStack(spacing: 0) {
                // Inset inside the wing frame; outside it the row overflows and the
                // icons touch the shape's edges.
                wing(cells.left, mirrored: false)
                    .padding(.leading, 10)
                    .frame(width: model.wingWidth, alignment: .leading)
                Spacer(minLength: model.notchWidth)
                wing(cells.right, mirrored: true)
                    .padding(.trailing, 10)
                    .frame(width: model.wingWidth, alignment: .trailing)
            }
            .padding(.horizontal, NotchShape.closedTop)
        }
    }

    private typealias Entry = (quota: QuotaData, cell: StripCell)

    private static func accessibilityLabel(_ entry: Entry?) -> String {
        guard let entry else { return "—" }
        return "\(entry.quota.provider == .codex ? "Codex" : "Claude") \(entry.cell.text)"
    }

    /// nil means no provider is tracked (the strip still carries the menu, so it stays, muted).
    private var cells: (left: Entry?, right: Entry?) {
        // Same gate as the floating rows: agent enabled and usage tracking on.
        let codexShown = codexAgentEnabled && codexUsageEnabled
            && QuotaMeterProviderVisibility.isVisible(.codex, hiddenProvidersRaw: hiddenRaw)
        let claudeShown = claudeAgentEnabled && claudeUsageEnabled
            && QuotaMeterProviderVisibility.isVisible(.claude, hiddenProvidersRaw: hiddenRaw)
        let codex = codexShown ? QuotaData.codex(from: codexUsage) : nil
        let claude = claudeShown ? QuotaData.claude(from: claudeUsage) : nil
        switch (codex, claude) {
        case let (c?, a?):
            return ((c, QuotaStripCellBuilder.cell(input(c))), (a, QuotaStripCellBuilder.cell(input(a))))
        case let (q?, nil), let (nil, q?):
            return ((q, QuotaStripCellBuilder.cell(input(q, only: .fiveHour))),
                    (q, QuotaStripCellBuilder.cell(input(q, only: .weekly))))
        case (nil, nil):
            return (nil, nil)
        }
    }

    @ViewBuilder
    private func wing(_ entry: Entry?, mirrored: Bool) -> some View {
        if let entry {
            QuotaStripWingCell(quota: entry.quota, cell: entry.cell, mirrored: mirrored)
        } else {
            Text("—")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }

    enum Window { case fiveHour, weekly }

    /// One provider filling both wings: each wing shows one window, tagged even when the
    /// provider lacks it ("∞ 5h"); the chip and the working count belong to the 5h wing.
    private func input(_ q: QuotaData, only window: Window) -> StripCellInput {
        var input = input(q)
        switch window {
        case .fiveHour:
            input.weekLeft = nil
            input.emptyTag = "5h"
        case .weekly:
            input.fiveHourLeft = nil
            input.emptyTag = "wk"
            input.workingSessions = 0
            input.finishedSessions = 0
        }
        return input
    }

    private func input(_ q: QuotaData) -> StripCellInput {
        let source: UsageTrackingSource = q.provider == .codex ? .codex : .claude
        var input = Self.baseInput(q, probing: probeCoordinator.displayState(for: source, now: Date()))
        input.showsUsed = UsageDisplayMode(rawValue: displayModeRaw) == .used
        input.showsProjection = projectionEnabled
        let sessions = sessionActivity(q.provider == .codex ? .codex : .claude)
        input.workingSessions = sessions.working
        input.finishedSessions = sessions.finished
        return input
    }

    /// Agent-level activity from live presences (probe directories excluded):
    /// - working: a session seen working within `tickHold` (so it does not flicker between
    ///   presence polls);
    /// - finished: a session that was working within `yourTurnWindow` but no longer is, so
    ///   it waits for the user. Sessions left idle for longer are not counted.
    private func sessionActivity(_ source: SessionSource) -> (working: Int, finished: Int) {
        let now = Date()
        let prefix = "\(source)|"
        var present: Set<String> = []
        var working = 0
        var finished = 0
        for presence in activeCodex.presences where presence.source == source {
            guard !CodexProbeConfig.isProbeWorkingDirectory(presence.workspaceRoot),
                  !ClaudeProbeConfig.isProbeWorkingDirectory(presence.workspaceRoot) else { continue }
            let key = prefix + (presence.sessionId ?? presence.sessionLogPath ?? presence.pid.map(String.init) ?? "")
            present.insert(key)
            if activeCodex.liveState(for: presence) == .activeWorking {
                model.lastWorkingAt[key] = now
            }
            guard let last = model.lastWorkingAt[key] else { continue }
            let since = now.timeIntervalSince(last)
            if since < QuotaStripModel.tickHold {
                working += 1
            } else if since < QuotaStripModel.yourTurnWindow {
                finished += 1
            }
        }
        // Forget this provider's sessions that have ended.
        model.lastWorkingAt = model.lastWorkingAt.filter { !$0.key.hasPrefix(prefix) || present.contains($0.key) }
        return (working, finished)
    }

    /// Same precedence as the floating window's provider row: sign-in first, then a running
    /// probe, then idle / reconnecting / live. The run-out label is the panel's own
    /// (`formatUsageProjectionLabel`), so it appears, ages out and rounds exactly as there.
    static func baseInput(_ q: QuotaData, probing: ProbeCoordinator.ProbeRowState = .none,
                          now: Date = Date()) -> StripCellInput {
        let state: StripCellInput.State
        switch q.presentationState {
        case .needsAction: state = .needsAction
        case _ where Self.isVisible(probing): state = .probing
        case .live: state = .live
        case .idle: state = .idle
        case .reconnecting: state = q.isRateLimited ? .limited : .retrying
        }
        return StripCellInput(
            state: state,
            fiveHourLeft: q.hasFiveHourRateLimit ? q.fiveHourRemainingPercent : nil,
            weekLeft: q.hasWeekRateLimit ? q.weekRemainingPercent : nil,
            projection: formatUsageProjectionLabel(runoutAt: q.fiveHourProjectedRunoutAt,
                                                   observedAt: q.fiveHourProjectionObservedAt, now: now))
    }

    private static func isVisible(_ probe: ProbeCoordinator.ProbeRowState) -> Bool {
        if case .none = probe { return false }
        return true
    }
}

enum QuotaStripPalette {
    static let healthy = Color(red: 0.36, green: 0.84, blue: 0.62)
    /// `hudProjectionColor`, dark variant: run-out chips and burn, as in the panel.
    static let projection = Color(red: 1.0, green: 0.60, blue: 0.12)

    static func tone(_ tone: StripCell.Tone) -> Color {
        switch tone {
        case .healthy: return healthy
        case .warning: return .orange
        case .critical: return .red
        case .muted: return Color.white.opacity(0.55)
        }
    }
}

struct QuotaStripWingCell: View {
    let quota: QuotaData
    let cell: StripCell
    let mirrored: Bool

    /// The right wing is the left wing in a mirror (owner 2026-10-19): icon · 54% wk · ● ·
    /// ▸2h on the left, ▸2h · ● · 5h 56% · icon on the right. When the wing is too narrow
    /// the working count goes first, then the chip, so nothing slides under the notch.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsWorking: true, showsChip: true)
            row(showsWorking: false, showsChip: true)
            row(showsWorking: false, showsChip: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private func row(showsWorking: Bool, showsChip: Bool) -> some View {
        HStack(alignment: .center, spacing: 4) {
            if mirrored {
                if showsChip { chipView }
                if showsWorking { workingView }
                HStack(alignment: .firstTextBaseline, spacing: 2) { tagView; numberView }
                icon
            } else {
                icon
                HStack(alignment: .firstTextBaseline, spacing: 2) { numberView; tagView }
                if showsWorking { workingView }
                if showsChip { chipView }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }

    private var numberView: some View {
        Text(cell.text).foregroundStyle(QuotaStripPalette.tone(cell.tone))
    }

    @ViewBuilder private var tagView: some View {
        if let tag = cell.tag {
            Text(tag).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// One agent-level mark (owner 2026-10-19): a dim white dot while a session works, a blue
    /// ring when one just finished and waits for the user. Not orange or green, so it never
    /// reads as the system's microphone/camera dots or as the burn colour. Session detail is
    /// in the panel.
    @ViewBuilder private var workingView: some View {
        switch cell.activity {
        case .none:
            EmptyView()
        case .working:
            Circle().fill(Color.white.opacity(0.7)).frame(width: 5, height: 5)
        case .yourTurn:
            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 7, height: 7)
        }
    }

    /// Same weight and colour as the panel's run-out token.
    @ViewBuilder private var chipView: some View {
        if let chip = cell.chip {
            Text(chip).bold().foregroundStyle(QuotaStripPalette.projection)
        }
    }

    private var accessibilityText: String {
        let name = quota.provider == .codex ? "Codex" : "Claude"
        var parts = ["\(name) \(cell.text)"]
        if let chip = cell.chip { parts.append(chip) }
        switch cell.activity {
        case .none: break
        case .working:
            parts.append(String(localized: "Working", comment: "Menu bar strip accessibility: a session of this agent is working."))
        case .yourTurn:
            parts.append(String(localized: "Your turn", comment: "Menu bar strip accessibility: a session of this agent finished and waits for the user."))
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var icon: some View {
        if quota.provider == .claude {
            Image("FooterIconClaude").renderingMode(.original).resizable().scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image("FooterIconCodex").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 14, height: 14).foregroundStyle(.white)
        }
    }
}

/// Minimal style: a 3 pt bar filled by the share left, coloured by the cell tone.
struct QuotaStripHairline: View {
    let cell: StripCell?
    let width: CGFloat
    /// One VoiceOver element per wing, as in the Wings style.
    let label: String

    var body: some View {
        ZStack(alignment: .leading) {
            // Mid-grey track: visible on light and dark menu bars alike.
            Capsule().fill(Color(white: 0.5, opacity: 0.45))
            if let cell, let fraction = cell.fillFraction {
                Capsule().fill(QuotaStripPalette.tone(cell.tone))
                    .frame(width: max(3, width * fraction))
            } else {
                Capsule().fill(Color.white.opacity(0.35))
            }
        }
        .frame(width: width, height: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// Hosting view that only takes events inside the current strip shape.
final class QuotaStripHostingView<Content: View>: NSHostingView<Content> {
    var hitRectProvider: () -> CGRect = { .zero }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Point in top-left-origin coordinates, whatever `isFlipped` is.
    func topLeft(_ p: NSPoint) -> NSPoint {
        isFlipped ? p : NSPoint(x: p.x, y: bounds.height - p.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = topLeft(convert(point, from: superview))
        return hitRectProvider().contains(local) ? super.hitTest(point) : nil
    }
}
