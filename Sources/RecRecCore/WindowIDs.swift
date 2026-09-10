import CoreGraphics

public enum WindowIDs {
    /// AppKit window numbers for windows that are not on screen can be negative (-1); those have no
    /// CGWindowID and must not be force-converted (UInt32 traps on negative values).
    public static func valid(_ windowNumbers: [Int]) -> Set<CGWindowID> {
        Set(windowNumbers.compactMap { number in
            guard number > 0, let id = CGWindowID(exactly: number) else { return nil }
            return id
        })
    }
}
