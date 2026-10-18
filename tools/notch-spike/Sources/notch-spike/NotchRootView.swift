import AppKit
import SwiftUI

/// Shared state between the controller and the SwiftUI notch view.
@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var minimal = false

    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let wingWidth: CGFloat = 104
    let virtual: Bool
    /// Measured once from the expanded content.
    var expandedSize: CGSize = .zero
    let panelSize: CGSize

    static let closedTop: CGFloat = 6, closedBottom: CGFloat = 14
    static let openTop: CGFloat = 19, openBottom: CGFloat = 24
    static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0)

    init(notchWidth: CGFloat, notchHeight: CGFloat, virtual: Bool) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.virtual = virtual
        let probe = NSHostingView(rootView: ExpandedBody(notchHeight: notchHeight))
        let fit = probe.fittingSize
        let collapsedWidth = wingWidth * 2 + notchWidth + Self.closedTop * 2
        expandedSize = CGSize(width: max(fit.width, collapsedWidth + 40), height: fit.height)
        // Room for the open shadow.
        panelSize = CGSize(width: expandedSize.width + 80, height: expandedSize.height + 50)
    }

    var collapsedSize: CGSize {
        minimal
            ? CGSize(width: notchWidth + Self.closedTop * 2, height: notchHeight)
            : CGSize(width: wingWidth * 2 + notchWidth + Self.closedTop * 2, height: notchHeight)
    }

    var shapeSize: CGSize { expanded ? expandedSize : collapsedSize }

    /// Interactive rect in panel coordinates, origin top-left.
    var hitRect: CGRect {
        let s = shapeSize
        return CGRect(x: (panelSize.width - s.width) / 2, y: 0, width: s.width, height: s.height)
    }
}

/// Expanded body: notch row spacer, then the Quota Meter rows.
struct ExpandedBody: View {
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            QuotaPanelContent()
        }
        .padding(.horizontal, NotchModel.openTop + 6)
        .padding(.bottom, 10)
        .fixedSize()
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let size = model.shapeSize
        let top = model.expanded ? NotchModel.openTop : NotchModel.closedTop
        let bottom = model.expanded ? NotchModel.openBottom : NotchModel.closedBottom
        VStack(spacing: 0) {
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

                if !model.expanded && !model.minimal {
                    HStack(spacing: 0) {
                        WingContent(quota: .codex, mirrored: false)
                            .padding(.leading, 10)
                            .frame(width: model.wingWidth, alignment: .leading)
                        Spacer(minLength: model.notchWidth)
                        WingContent(quota: .claude, mirrored: true)
                            .padding(.trailing, 10)
                            .frame(width: model.wingWidth, alignment: .trailing)
                    }
                    .padding(.horizontal, NotchModel.closedTop)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
                }

                if model.expanded {
                    ExpandedBody(notchHeight: model.notchHeight)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.98, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.easeOut(duration: 0.22).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                }
            }
            if model.minimal && !model.expanded {
                Hairlines(model: model).transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Minimal style: two 3 pt bars under the notch, filled by percent left.
struct Hairlines: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: model.notchWidth) {
            bar(ProviderQuota.codex)
            bar(ProviderQuota.claude)
        }
        .padding(.top, 2)
    }

    private func bar(_ q: ProviderQuota) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            Capsule().fill(QM.percentColor(q.fiveHourLeft, healthyIsGreen: true))
                .frame(width: model.wingWidth * CGFloat(q.fiveHourLeft) / 100)
        }
        .frame(width: model.wingWidth, height: 3)
    }
}

/// Hosting view that only takes events inside the current notch shape.
final class NotchHostingView: NSHostingView<NotchRootView> {
    var hitRectProvider: () -> CGRect = { .zero }
    var onClick: (NSPoint) -> Void = { _ in }
    var onRightClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Point in top-left-origin coordinates, whatever `isFlipped` is.
    private func topLeft(_ p: NSPoint) -> NSPoint {
        isFlipped ? p : NSPoint(x: p.x, y: bounds.height - p.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = topLeft(convert(point, from: superview))
        return hitRectProvider().contains(local) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick(topLeft(convert(event.locationInWindow, from: nil)))
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick()
    }
}
