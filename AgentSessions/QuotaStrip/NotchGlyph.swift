import SwiftUI

/// "Move Quota Meter to Notch" glyph: the top edge of the screen, the notch hanging from
/// it, and an arrow pointing up into the notch. No SF Symbol means "notch". Drawn in the
/// inherited foreground style so it follows the toolbar button states like the SF Symbols
/// beside it. Geometry comes from the owner-approved mockup (15 × 11 design units).
struct NotchGlyph: View {
    var body: some View {
        ZStack {
            NotchGlyphEdgeAndNotch().fill(.foreground)
            NotchGlyphArrow()
                .stroke(.foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 15, height: 11)
        .accessibilityHidden(true)
    }
}

/// Scales a point from the 15 × 11 design grid into `rect`.
private func glyphPoint(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x / 15 * rect.width, y: rect.minY + y / 11 * rect.height)
}

/// The top edge (a 1.2-unit bar across the full width) and the filled notch below it.
private struct NotchGlyphEdgeAndNotch: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 15, sy = rect.height / 11
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: rect.minY + 0.4 * sy, width: rect.width, height: 1.2 * sy))
        let notch = CGRect(x: rect.minX + 4 * sx, y: rect.minY + 1 * sy, width: 7 * sx, height: 3.5 * sy)
        path.addPath(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 1.7 * sx,
                                            bottomTrailingRadius: 1.7 * sx, topTrailingRadius: 0)
            .path(in: notch))
        return path
    }
}

/// The up arrow under the notch.
private struct NotchGlyphArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: glyphPoint(7.5, 10.2, in: rect))
        path.addLine(to: glyphPoint(7.5, 6.4, in: rect))
        path.move(to: glyphPoint(5.6, 8.1, in: rect))
        path.addLine(to: glyphPoint(7.5, 6.2, in: rect))
        path.addLine(to: glyphPoint(9.4, 8.1, in: rect))
        return path
    }
}
