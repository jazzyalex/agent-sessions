import AppKit
import SwiftUI

/// Shared state between `QuotaStripController` and the SwiftUI strip.
@MainActor
final class QuotaStripModel: ObservableObject {
    @Published var expanded = false
    /// The full Quota Meter is mounted only around hover (from pointer-enter until shortly
    /// after collapse), so the collapsed strip runs no timers, spinners or runway loop.
    @Published var contentMounted = false
    /// Measured from the expanded Quota Meter content (notch row included). Remembered across
    /// rebuilds so the first open after a rebuild starts at the right size.
    @Published var expandedContentSize: CGSize = QuotaStripModel.lastExpandedContentSize {
        didSet { Self.lastExpandedContentSize = expandedContentSize }
    }
    private static var lastExpandedContentSize = CGSize(width: 440, height: 220)

    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let wingWidth = QuotaStripGeometry.wingWidth
    /// Room around the open shape for its shadow.
    static let shadowMargin = CGSize(width: 40, height: 50)

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    var collapsedSize: CGSize {
        CGSize(width: wingWidth * 2 + notchWidth + NotchShape.closedTop * 2, height: notchHeight)
    }

    var expandedSize: CGSize {
        CGSize(width: max(expandedContentSize.width + (NotchShape.openTop + 6) * 2, collapsedSize.width + 40),
               height: expandedContentSize.height + 10)
    }

    var shapeSize: CGSize { expanded ? expandedSize : collapsedSize }

    var panelSize: CGSize {
        CGSize(width: expandedSize.width + Self.shadowMargin.width * 2,
               height: expandedSize.height + Self.shadowMargin.height)
    }

    /// Interactive rect in panel coordinates, origin top-left.
    var hitRect: CGRect {
        let s = shapeSize
        return CGRect(x: (panelSize.width - s.width) / 2, y: 0, width: s.width, height: s.height)
    }
}

private struct ExpandedContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct QuotaStripRootView<Expanded: View>: View {
    @ObservedObject var model: QuotaStripModel
    let expandedContent: Expanded

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
                QuotaStripWings(model: model)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }

            // Mounted from hover-enter (during the open dwell, so it is measured and loaded
            // before the shape grows) until shortly after collapse; visible only while expanded.
            if model.contentMounted {
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notchHeight)
                    expandedContent
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
            model.expandedContentSize = size
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Collapsed wings (mockup A): Codex on the left, Claude on the right. With one provider
/// visible, it takes both wings (5h left, weekly right).
struct QuotaStripWings: View {
    @ObservedObject var model: QuotaStripModel
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
        let providers = visibleProviders
        HStack(spacing: 0) {
            // Inset inside the wing frame; outside it the row overflows and the
            // icons touch the shape's edges.
            wing(for: providers.left, mirrored: false)
                .padding(.leading, 10)
                .frame(width: model.wingWidth, alignment: .leading)
            Spacer(minLength: model.notchWidth)
            wing(for: providers.right, mirrored: true)
                .padding(.trailing, 10)
                .frame(width: model.wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, NotchShape.closedTop)
    }

    private enum Slot { case provider(QuotaData), window(QuotaData, weekly: Bool), untracked }

    private var visibleProviders: (left: Slot, right: Slot) {
        // Same gate as the floating rows: agent enabled and usage tracking on.
        let codexShown = codexAgentEnabled && codexUsageEnabled
            && QuotaMeterProviderVisibility.isVisible(.codex, hiddenProvidersRaw: hiddenRaw)
        let claudeShown = claudeAgentEnabled && claudeUsageEnabled
            && QuotaMeterProviderVisibility.isVisible(.claude, hiddenProvidersRaw: hiddenRaw)
        let codex = codexShown ? QuotaData.codex(from: codexUsage) : nil
        let claude = claudeShown ? QuotaData.claude(from: claudeUsage) : nil
        switch (codex, claude) {
        case let (c?, a?): return (.provider(c), .provider(a))
        case let (c?, nil): return (.window(c, weekly: false), .window(c, weekly: true))
        case let (nil, a?): return (.window(a, weekly: false), .window(a, weekly: true))
        case (nil, nil): return (.untracked, .untracked)
        }
    }

    @ViewBuilder
    private func wing(for slot: Slot, mirrored: Bool) -> some View {
        switch slot {
        case .provider(let q):
            QuotaStripWingCell(quota: q, cell: QuotaStripCellBuilder.cell(input(q)), mirrored: mirrored)
        case .window(let q, let weekly):
            QuotaStripWingCell(quota: q, cell: QuotaStripCellBuilder.cell(input(q, only: weekly ? .weekly : .fiveHour)),
                               mirrored: mirrored)
        case .untracked:
            // No provider tracked: the strip still carries the menu, so it stays, muted.
            Text("—")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }

    enum Window { case fiveHour, weekly }

    /// One provider filling both wings: each wing shows one window; the run-out chip
    /// belongs to the left (5h) wing only.
    private func input(_ q: QuotaData, only window: Window) -> StripCellInput {
        var input = input(q)
        switch window {
        case .fiveHour: input.weekLeft = nil
        case .weekly:
            input.fiveHourLeft = nil
            input.showsProjection = false
        }
        return input
    }

    private func input(_ q: QuotaData) -> StripCellInput {
        var input = Self.baseInput(q)
        input.showsUsed = UsageDisplayMode(rawValue: displayModeRaw) == .used
        input.showsProjection = projectionEnabled
        return input
    }

    static func baseInput(_ q: QuotaData, now: Date = Date()) -> StripCellInput {
        let state: StripCellInput.State
        switch q.presentationState {
        case .live: state = .live
        case .needsAction: state = .needsAction
        case .idle: state = .idle
        case .reconnecting: state = q.isRateLimited ? .limited : .retrying
        }
        return StripCellInput(
            state: state,
            fiveHourLeft: q.hasFiveHourRateLimit ? q.fiveHourRemainingPercent : nil,
            weekLeft: q.hasWeekRateLimit ? q.weekRemainingPercent : nil,
            projectedRunout: q.fiveHourProjectedRunoutAt,
            fiveHourResetAt: q.resetDate(kind: "5h", raw: q.fiveHourResetText),
            now: now)
    }
}

struct QuotaStripWingCell: View {
    let quota: QuotaData
    let cell: StripCell
    let mirrored: Bool

    static let healthy = Color(red: 0.36, green: 0.84, blue: 0.62)
    /// `hudProjectionColor`, dark variant.
    static let projection = Color(red: 1.0, green: 0.60, blue: 0.12)

    var body: some View {
        HStack(spacing: 5) {
            if !mirrored { icon }
            HStack(spacing: 2) {
                Text(cell.text).foregroundStyle(toneColor)
                if let tag = cell.tag {
                    Text(tag).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            if let chip = cell.chip {
                Text(chip).foregroundStyle(cell.chipWarns ? Self.projection : Color.white.opacity(0.72))
            }
            if mirrored { icon }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(quota.provider == .codex ? "Codex" : "Claude") \(cell.text)"))
    }

    private var toneColor: Color {
        switch cell.tone {
        case .healthy: return Self.healthy
        case .warning: return .orange
        case .critical: return .red
        case .muted: return Color.white.opacity(0.55)
        }
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
