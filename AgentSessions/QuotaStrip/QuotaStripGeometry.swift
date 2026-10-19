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
