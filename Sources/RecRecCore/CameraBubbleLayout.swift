import CoreGraphics

/// Where the camera bubble goes on screen. Coordinates are AppKit's (origin bottom-left) and
/// `visibleFrame` is the screen area without the menu bar and Dock.
public enum CameraBubbleLayout {
    public static let margin: CGFloat = 24

    public static func frame(corner: CameraCorner, diameter: CGFloat, in visibleFrame: CGRect, margin: CGFloat = margin) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft, .bottomLeft: x = visibleFrame.minX + margin
        case .topRight, .bottomRight: x = visibleFrame.maxX - margin - diameter
        }
        switch corner {
        case .topLeft, .topRight: y = visibleFrame.maxY - margin - diameter
        case .bottomLeft, .bottomRight: y = visibleFrame.minY + margin
        }
        return clamped(CGRect(x: x, y: y, width: diameter, height: diameter), to: visibleFrame)
    }

    /// Moves a frame so it lies inside `visibleFrame` (a bubble dragged off screen or left behind by a
    /// display change comes back into view).
    public static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        var result = frame
        if result.width > visibleFrame.width { result.origin.x = visibleFrame.minX }
        else { result.origin.x = min(max(result.origin.x, visibleFrame.minX), visibleFrame.maxX - result.width) }
        if result.height > visibleFrame.height { result.origin.y = visibleFrame.minY }
        else { result.origin.y = min(max(result.origin.y, visibleFrame.minY), visibleFrame.maxY - result.height) }
        return result
    }
}
