import Foundation
import CoreGraphics

/// Menu bar strip geometry in Cocoa screen coordinates (origin bottom-left).
/// Pure: compiled into the app and the hostless logic-test target.
struct QuotaStripLayout: Equatable {
    let notch: CGRect
    let leftWing: CGRect
    let rightWing: CGRect
    /// True on a screen without a hardware notch (virtual notch at the top centre).
    let isVirtual: Bool
}

enum QuotaStripGeometry {
    static let wingWidth: CGFloat = 104
    static let virtualNotchWidth: CGFloat = 24
    static let fallbackMenuBarHeight: CGFloat = 24

    static func layout(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxLeftWidth: CGFloat?,
        auxRightWidth: CGFloat?
    ) -> QuotaStripLayout {
        let notch: CGRect
        let isVirtual: Bool
        if safeAreaTop > 0, let auxLeftWidth, let auxRightWidth {
            // Widths are the same in screen-local and global coordinates; origins are not.
            let minX = screenFrame.minX + auxLeftWidth
            notch = CGRect(x: minX, y: screenFrame.maxY - safeAreaTop,
                           width: screenFrame.maxX - auxRightWidth - minX, height: safeAreaTop)
            isVirtual = false
        } else {
            let menuBar = screenFrame.maxY - visibleFrame.maxY
            let height = menuBar > 0 ? menuBar : fallbackMenuBarHeight
            notch = CGRect(x: screenFrame.midX - virtualNotchWidth / 2, y: screenFrame.maxY - height,
                           width: virtualNotchWidth, height: height)
            isVirtual = true
        }
        return QuotaStripLayout(
            notch: notch,
            leftWing: CGRect(x: notch.minX - wingWidth, y: notch.minY, width: wingWidth, height: notch.height),
            rightWing: CGRect(x: notch.maxX, y: notch.minY, width: wingWidth, height: notch.height),
            isVirtual: isVirtual)
    }
}

/// Sizes and hit area of the strip panel, in panel coordinates (origin top-left). Pure, so the
/// Wings / Minimal geometry is covered by the hostless logic tests.
struct QuotaStripSizing: Equatable {
    /// Notch silhouette radii (the flare is `closedTopRadius` wide on each side when closed).
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14
    static let openTopRadius: CGFloat = 19
    static let openBottomRadius: CGFloat = 24
    /// Room around the open shape for its shadow.
    static let shadowMargin = CGSize(width: 40, height: 50)

    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var wingWidth: CGFloat = QuotaStripGeometry.wingWidth

    /// Wing · notch · wing with both flares; the panel and the open shape never get narrower.
    var wingsWidth: CGFloat { wingWidth * 2 + notchWidth + Self.closedTopRadius * 2 }

    /// Minimal: the notch alone (plus flares), which is also the hover and click target.
    func collapsedSize(minimal: Bool) -> CGSize {
        CGSize(width: minimal ? notchWidth + Self.closedTopRadius * 2 : wingsWidth, height: notchHeight)
    }

    /// The open shape around the measured Quota Meter content (notch row included).
    func expandedSize(content: CGSize) -> CGSize {
        CGSize(width: max(content.width + (Self.openTopRadius + 6) * 2, wingsWidth + 40),
               height: content.height + 10)
    }

    /// Independent of the style, so switching Wings / Minimal never moves the panel.
    func panelSize(content: CGSize) -> CGSize {
        let open = expandedSize(content: content)
        return CGSize(width: open.width + Self.shadowMargin.width * 2, height: open.height + Self.shadowMargin.height)
    }

    /// The current shape, centred at the top of the panel.
    func hitRect(expanded: Bool, minimal: Bool, content: CGSize) -> CGRect {
        let shape = expanded ? expandedSize(content: content) : collapsedSize(minimal: minimal)
        let panel = panelSize(content: content)
        return CGRect(x: (panel.width - shape.width) / 2, y: 0, width: shape.width, height: shape.height)
    }
}
