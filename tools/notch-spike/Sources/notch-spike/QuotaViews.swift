import AppKit
import SwiftUI

// Fake data drawn in the real Quota Meter style (AgentCockpitHUDView: HUDLimitsRowsPanel,
// HUDRunwayPanel, HUDRunwayLoadBar). Values are static; only the runway bars move.

enum Provider: String { case codex, claude }

struct RunwaySession: Identifiable {
    enum Confidence { case direct, mixed, waiting, idle, cloud }
    let id = UUID()
    let name: String
    let rate: Double          // minutes of quota per hour
    let confidence: Confidence
}

struct ProviderQuota {
    let provider: Provider
    let fiveHourLeft: Int
    let projection: String?   // "▸2h" style run-out chip
    let fiveHourReset: String
    let weeklyLeft: Int
    let weeklyReset: String
    let willRunOut: Bool
    let sessions: [RunwaySession]
    let moreSessions: Int

    static let codex = ProviderQuota(
        provider: .codex, fiveHourLeft: 62, projection: "▸2h 5m", fiveHourReset: "↻ 3h 12m",
        weeklyLeft: 81, weeklyReset: "↻ Wed 12:00 PM", willRunOut: false,
        sessions: [
            RunwaySession(name: "agent-sessions · notch strip", rate: 137, confidence: .direct),
            RunwaySession(name: "repo-mcp · review pass", rate: 42, confidence: .mixed),
            RunwaySession(name: "pricing manifest", rate: 0, confidence: .waiting),
        ],
        moreSessions: 0)

    static let claude = ProviderQuota(
        provider: .claude, fiveHourLeft: 24, projection: "▸40m", fiveHourReset: "↻ 1h 05m",
        weeklyLeft: 58, weeklyReset: "↻ Thu 9:00 AM", willRunOut: true,
        sessions: [
            RunwaySession(name: "Codex-History · main", rate: 88, confidence: .direct),
            RunwaySession(name: "marketing · release notes", rate: 19, confidence: .mixed),
        ],
        moreSessions: 2)
}

enum QM {
    static let font = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let runwayFont = Font.system(size: 11, weight: .medium, design: .monospaced)
    /// hudProjectionColor, dark variant.
    static let orange = Color(red: 1.0, green: 0.60, blue: 0.12)
    static let healthy = Color(red: 0.36, green: 0.84, blue: 0.62)

    /// Quota Meter percent colour rule, with the strip's green for healthy.
    static func percentColor(_ left: Int, healthyIsGreen: Bool) -> Color {
        if left <= 10 { return .red }
        if left < 30 { return .orange }
        return healthyIsGreen ? healthy : .white
    }

    static func icon(_ provider: Provider) -> some View {
        ProviderIcon(provider: provider)
    }
}

struct ProviderIcon: View {
    let provider: Provider

    var body: some View {
        if let image = Self.load(provider) {
            Image(nsImage: image)
                .renderingMode(provider == .codex ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
        } else {
            Circle().fill(provider == .codex ? Color.white : Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: 10, height: 10)
        }
    }

    private static func load(_ provider: Provider) -> NSImage? {
        guard let url = Bundle.module.url(forResource: provider.rawValue, withExtension: "svg",
                                          subdirectory: "Resources") else { return nil }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = provider == .codex
        return image
    }
}

// MARK: - Collapsed strip content (mockup A)

/// One wing's content: icon, percent, run-out chip. Codex on the left, Claude on the right.
struct WingContent: View {
    let quota: ProviderQuota
    let mirrored: Bool

    var body: some View {
        HStack(spacing: 5) {
            if !mirrored { QM.icon(quota.provider) }
            Text("\(quota.fiveHourLeft)%")
                .foregroundStyle(QM.percentColor(quota.fiveHourLeft, healthyIsGreen: true))
            if let chip = quota.projection?.split(separator: " ").first {
                Text(chip)
                    .foregroundStyle(quota.willRunOut ? QM.orange : Color.white.opacity(0.72))
            }
            if mirrored { QM.icon(quota.provider) }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Expanded panel content (the Quota Meter, dark)

struct QuotaPanelContent: View {
    let blocks: [ProviderQuota] = [.codex, .claude]
    @State private var tick = 0
    private let ticker = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, quota in
                if index > 0 {
                    Color.clear.frame(height: 7)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                }
                LimitsRow(quota: quota)
                RunwayPanel(quota: quota, tick: tick)
            }
        }
        .padding(.bottom, 6)
        .environment(\.colorScheme, .dark)
        .onReceive(ticker) { _ in tick = (tick + 1) % 1024 }
    }
}

struct LimitsRow: View {
    let quota: ProviderQuota

    var body: some View {
        HStack(spacing: 8) {
            QM.icon(quota.provider)
            HStack(spacing: 6) {
                Text("5h: \(quota.fiveHourLeft)%")
                    .foregroundStyle(QM.percentColor(quota.fiveHourLeft, healthyIsGreen: false))
                    .frame(width: 53, alignment: .leading)
                Text(quota.projection.map { " \($0)" } ?? "·")
                    .bold()
                    .foregroundStyle(quota.projection == nil ? Color.secondary : QM.orange)
                    .frame(width: 60, alignment: .leading)
                Text(quota.fiveHourReset).frame(width: 60, alignment: .leading)
                Text("|").foregroundStyle(Color.white.opacity(0.25)).frame(width: 5)
                Text("Wk: \(quota.weeklyLeft)%")
                    .foregroundStyle(QM.percentColor(quota.weeklyLeft, healthyIsGreen: false))
                    .frame(width: 53, alignment: .leading)
                Text(quota.weeklyReset).frame(width: 104, alignment: .leading)
            }
            .font(QM.font)
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

struct RunwayPanel: View {
    let quota: ProviderQuota
    let tick: Int

    private var maxRate: Double { max(quota.sessions.map(\.rate).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(quota.sessions.enumerated()), id: \.element.id) { index, session in
                RunwayRow(name: session.name, rate: session.rate, confidence: session.confidence,
                          maxRate: maxRate, index: index, tick: tick)
            }
            if quota.moreSessions > 0 {
                RunwayRow(name: "+\(quota.moreSessions) sessions", rate: 6, confidence: .mixed,
                          maxRate: maxRate, index: quota.sessions.count, tick: tick, isSummary: true)
            }
        }
        .font(QM.runwayFont)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}

struct RunwayRow: View {
    let name: String
    let rate: Double
    let confidence: RunwaySession.Confidence
    let maxRate: Double
    let index: Int
    let tick: Int
    var isSummary = false

    private var burning: Bool { (confidence == .direct || confidence == .mixed) && rate >= 0.5 }

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .foregroundStyle(isSummary ? Color.secondary : Color.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            rateText.frame(width: 52, alignment: .trailing)
            LoadBar(fraction: burning ? fillFraction : 0)
                .frame(width: 110)
        }
        .frame(height: 14)
    }

    @ViewBuilder private var rateText: some View {
        switch confidence {
        case .waiting: Text("0m/h").foregroundStyle(.secondary)
        case .idle: Text("—").foregroundStyle(.secondary)
        case .cloud: Text("Cloud").foregroundStyle(.secondary)
        case .direct, .mixed:
            if rate >= 0.5 {
                Text("\(Int(rate.rounded(.up)))m/h").foregroundStyle(QM.orange)
            } else {
                Text("quiet").foregroundStyle(.secondary)
            }
        }
    }

    /// HUDRunwayLoadBar fill rule for m/h, with the 0.8 s breathing wave.
    private var fillFraction: Double {
        let rel = rate / maxRate
        let base = max(0.12, rel * 0.60 + min(1, rate / 45) * 0.30)
        let wave = 0.82 + 0.18 * sin(Double(tick + index * 3) * 0.9)
        return min(1, max(0.04, base * wave))
    }
}

struct LoadBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(QM.orange.opacity(0.82))
                    .frame(width: proxy.size.width * fraction)
                    .animation(.easeInOut(duration: 0.28), value: fraction)
            }
        }
        .frame(height: 5)
    }
}
