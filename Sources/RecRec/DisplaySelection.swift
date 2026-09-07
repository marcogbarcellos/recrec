import AppKit
import ScreenCaptureKit

enum DisplaySelection {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    /// Connected displays with a human-readable label for the menu.
    static func connectedDisplays() -> [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[screenNumberKey] as? UInt32 else { return nil }
            let size = pixelSize(of: id)
            return (id, "\(screen.localizedName) (\(Int(size.width))×\(Int(size.height)))")
        }
    }

    static func displayIDUnderMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.deviceDescription[screenNumberKey] as? CGDirectDisplayID
    }

    /// Physical pixel size of a display (SCDisplay reports points).
    static func pixelSize(of displayID: CGDirectDisplayID) -> CGSize {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
        }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    /// The pinned display if still connected, else the one under the mouse, else the main display, else the first.
    static func choose(from displays: [SCDisplay], pinned: UInt32?) -> SCDisplay? {
        if let pinned, let display = displays.first(where: { $0.displayID == pinned }) { return display }
        if let under = displayIDUnderMouse(), let display = displays.first(where: { $0.displayID == under }) { return display }
        if let display = displays.first(where: { $0.displayID == CGMainDisplayID() }) { return display }
        return displays.first
    }
}
