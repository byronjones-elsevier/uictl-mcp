import ScreenCaptureKit
import CoreGraphics

/// Global-Quartz coordinates (what every `"frame"` in this tool's JSON output
/// uses) are relative to the *primary* display's top-left corner, not each
/// display's own — so a display positioned left of or above the primary one
/// in System Settings > Displays has negative x/y in its bounds. `list()`
/// surfaces that topology explicitly so callers don't have to guess it from
/// window frames alone.
enum Displays {
    static func list() throws -> [JSONDict] {
        try runSync {
            let content = try await SCShareableContent.current
            return content.displays.enumerated().map { index, display -> JSONDict in
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let bounds = CGDisplayBounds(display.displayID)
                return [
                    "index": index,
                    "displayId": Int(display.displayID),
                    "frame": bounds.jsonDict,
                    "isMain": display.displayID == CGMainDisplayID(),
                    "pointPixelScale": Double(filter.pointPixelScale),
                ]
            }
        }
    }

    /// The display whose bounds contain `point`, or nil if none does. Plain
    /// CoreGraphics rather than ScreenCaptureKit — synchronous and cheap
    /// enough to call once per window in `AppsAndWindows.listWindows`,
    /// unlike the `SCShareableContent.current` round trip `list()` uses.
    static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(point, 1, &display, &count)
        guard result == .success, count > 0 else { return nil }
        return display
    }
}
