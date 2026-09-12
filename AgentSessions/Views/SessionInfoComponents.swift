import SwiftUI

/// Small building blocks for the Session info inspector. Sizes come from the
/// locked mockup (docs/superpowers/plans/assets/2026-09-10-session-info-inspector-mockup.html);
/// spacing comes from LayoutTokens; every color is semantic.
enum SessionInfoType {
    static let hero = Font.system(size: 27, weight: .semibold)
    static let subhero = Font.system(size: 14, weight: .semibold)
    static let sectionHead = Font.system(size: 10.5, weight: .semibold)
    static let row = Font.system(size: 11.5)
    static let caption = Font.system(size: 10.5)
}

/// Shared fills, so the bar segment and its legend swatch can never drift apart.
enum SessionInfoPalette {
    static let cached = AnyShapeStyle(Color.secondary.opacity(0.55))
    static let fresh = AnyShapeStyle(Color.accentColor)
    static let output = AnyShapeStyle(Color.orange)
}

struct SessionInfoSection<Content: View>: View {
    let title: LocalizedStringResource?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.sm) {
            if let title {
                Text(title)
                    .font(SessionInfoType.sectionHead)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label/value line: secondary label left, tabular value right. The value is
/// dimmed when it is the em dash, so an absent field reads as absent at a glance.
struct SessionInfoRow: View {
    let label: String.LocalizationValue
    let value: TranscriptTelemetryPresentation.Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.md) {
            Text(LocalizedStringResource(label))
                .font(SessionInfoType.row)
                .foregroundStyle(.secondary)
            Spacer(minLength: LayoutTokens.sm)
            Text(verbatim: value.text)
                .font(SessionInfoType.row)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(value.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .help(Text(verbatim: value.help))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: TranscriptTelemetryPresentation.rowAccessibilityLabel(
            label: label,
            value: value.text
        )))
    }
}

/// Cached / fresh / output as one bar. Segments below 1% keep a hairline width so
/// a real-but-tiny share (output is routinely 0.3%) does not vanish.
struct TokenShareBar: View {
    let share: TelemetryTokenShare
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.xs) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    segment(share.cachedFraction, width: geometry.size.width, color: SessionInfoPalette.cached)
                    segment(share.freshFraction, width: geometry.size.width, color: SessionInfoPalette.fresh)
                    segment(share.outputFraction, width: geometry.size.width, color: SessionInfoPalette.output)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            HStack(spacing: LayoutTokens.md) {
                legend("Cached", share.cached, SessionInfoPalette.cached)
                legend("Fresh", share.fresh, SessionInfoPalette.fresh)
                legend("Output", share.output, SessionInfoPalette.output)
            }
        }
        .help(Text(verbatim: helpText))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: helpText))
    }

    private var helpText: String {
        TranscriptTelemetryPresentation.tokenShareHelp(share, locale: locale)
    }

    private func segment(_ fraction: Double, width: CGFloat, color: AnyShapeStyle) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: fraction > 0 ? max(1, width * fraction) : 0)
    }

    private func legend(_ name: LocalizedStringResource, _ tokens: Int, _ color: AnyShapeStyle) -> some View {
        HStack(spacing: LayoutTokens.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            // One fraction digit: plain compactName rounds 17,892,480 to "18M",
            // which reads as a suspiciously round number for a measured total.
            (Text(name) + Text(verbatim: " " + tokens.formatted(
                .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale)
            )))
                .font(SessionInfoType.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The configuration-change timeline. A row with a resolvable block index is a
/// button that jumps the transcript to that change's inline marker; a row without
/// one (Terminal or JSON mode, or an unmapped record) is static text.
struct SessionInfoHistoryList: View {
    let rows: [SessionInfoHistoryRow]
    let jump: ((Int) -> Void)?
    @Environment(\.locale) private var locale

    /// Above this many rows the list scrolls in place instead of growing. Real
    /// sessions carry 0-3 changes, so the common case never nests a scroll view.
    private static let unscrolledRowLimit = 4
    /// Four rows at their rendered height, so the bound crops mid-row and reads
    /// as scrollable rather than looking like the end of the list.
    private static let scrolledHeight: CGFloat = 132

    var body: some View {
        if rows.isEmpty {
            Text("No changes recorded")
                .font(SessionInfoType.row)
                .foregroundStyle(.secondary)
        } else if rows.count > Self.unscrolledRowLimit {
            ScrollView {
                list
            }
            .frame(height: Self.scrolledHeight)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                rowView(row)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SessionInfoHistoryRow) -> some View {
        let content = HStack(alignment: .top, spacing: LayoutTokens.sm) {
            pip(row)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title)
                    .font(SessionInfoType.row)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(verbatim: subtitle(row))
                    .font(SessionInfoType.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: LayoutTokens.xs)
            if jump != nil, row.blockIndex != nil {
                Image(systemName: "arrow.up.forward")
                    .font(SessionInfoType.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, LayoutTokens.sm)
        .contentShape(Rectangle())

        if let jump, let target = row.blockIndex {
            Button { jump(target) } label: { content }
                .buttonStyle(.plain)
                .help("Show this change in the transcript")
        } else {
            content
        }
    }

    private func pip(_ row: SessionInfoHistoryRow) -> some View {
        Circle()
            .strokeBorder(row.kind == .started ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.clear),
                          lineWidth: 1.5)
            .background(Circle().fill(row.kind == .started
                                      ? AnyShapeStyle(Color.clear)
                                      : AnyShapeStyle(Color.accentColor)))
            .frame(width: 7, height: 7)
    }

    private func subtitle(_ row: SessionInfoHistoryRow) -> String {
        TranscriptTelemetryPresentation.historySubtitle(row, locale: locale)
    }
}
