import CoreGraphics

public struct SpikeLayout: Equatable {
    public let notch: CGRect
    public let leftWing: CGRect
    public let rightWing: CGRect
    public let leftHairline: CGRect
    public let rightHairline: CGRect
    public let sensor: CGRect
    public let dropPanel: CGRect
}

/// Cocoa coordinates, origin bottom-left.
public enum SpikeGeometry {
    /// Strip around the hardware notch. Nil when the screen has no notch.
    public static func layout(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxLeft: CGRect?,
        auxRight: CGRect?,
        wingWidth: CGFloat = 95,
        hairline: CGFloat = 3,
        dropSize: CGSize = CGSize(width: 620, height: 190)
    ) -> SpikeLayout? {
        guard safeAreaTop > 0, let auxLeft, let auxRight else { return nil }
        // Widths are the same in screen-local and global coordinates; origins are not.
        let notchMinX = screenFrame.minX + auxLeft.width
        let notch = CGRect(x: notchMinX, y: screenFrame.maxY - safeAreaTop,
                           width: screenFrame.maxX - auxRight.width - notchMinX, height: safeAreaTop)
        return around(notch, wingWidth: wingWidth, hairline: hairline, dropSize: dropSize)
    }

    /// Strip around a virtual notch at the top centre of a screen without one.
    public static func virtualLayout(
        screenFrame: CGRect,
        menuBarHeight: CGFloat,
        sensorWidth: CGFloat = 24,
        wingWidth: CGFloat = 95,
        hairline: CGFloat = 3,
        dropSize: CGSize = CGSize(width: 620, height: 190)
    ) -> SpikeLayout {
        let height = menuBarHeight > 0 ? menuBarHeight : 24
        let notch = CGRect(x: screenFrame.midX - sensorWidth / 2, y: screenFrame.maxY - height,
                           width: sensorWidth, height: height)
        return around(notch, wingWidth: wingWidth, hairline: hairline, dropSize: dropSize)
    }

    private static func around(_ notch: CGRect, wingWidth: CGFloat, hairline: CGFloat,
                               dropSize: CGSize) -> SpikeLayout {
        let leftWing = CGRect(x: notch.minX - wingWidth, y: notch.minY, width: wingWidth, height: notch.height)
        let rightWing = CGRect(x: notch.maxX, y: notch.minY, width: wingWidth, height: notch.height)
        let leftHairline = CGRect(x: leftWing.minX, y: notch.minY - hairline, width: wingWidth, height: hairline)
        let rightHairline = CGRect(x: rightWing.minX, y: notch.minY - hairline, width: wingWidth, height: hairline)
        let dropPanel = CGRect(x: notch.midX - dropSize.width / 2, y: notch.minY - dropSize.height,
                               width: dropSize.width, height: dropSize.height)
        return SpikeLayout(notch: notch, leftWing: leftWing, rightWing: rightWing,
                           leftHairline: leftHairline, rightHairline: rightHairline,
                           sensor: notch, dropPanel: dropPanel)
    }
}
