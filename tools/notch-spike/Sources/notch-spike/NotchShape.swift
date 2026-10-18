import SwiftUI

/// Notch silhouette: flat top flush with the screen edge, concave flares where it meets the
/// menu bar, rounded bottom corners. The frame includes the flares (`topRadius` each side).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Collapsed strip (mockup A): one black shape across wing · notch · wing.
struct StripView: View {
    let notchWidth: CGFloat
    let height: CGFloat
    var wingWidth: CGFloat = 95
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat = 10

    var body: some View {
        ZStack {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).fill(.black)
            HStack(spacing: 0) {
                WingContent(quota: .codex, mirrored: false)
                    .frame(width: wingWidth, alignment: .leading)
                    .padding(.leading, 10)
                Spacer(minLength: notchWidth)
                WingContent(quota: .claude, mirrored: true)
                    .frame(width: wingWidth, alignment: .trailing)
                    .padding(.trailing, 10)
            }
            .padding(.horizontal, topRadius)
        }
        .frame(width: wingWidth * 2 + notchWidth + topRadius * 2, height: height)
    }
}

/// Expanded state: the notch grows into the Quota Meter.
struct ExpandedView: View {
    var topRadius: CGFloat = 12
    var bottomRadius: CGFloat = 20
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            QuotaPanelContent()
        }
        .padding(.horizontal, topRadius + 4)
        .padding(.bottom, 8)
        .background(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).fill(.black))
        .fixedSize()
    }
}
