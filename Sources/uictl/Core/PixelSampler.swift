import AppKit
import ScreenCaptureKit
import CoreGraphics

enum PixelSampler {
    static func colorAt(point: CGPoint) throws -> JSONDict {
        try runSync {
            let content = try await SCShareableContent.current
            guard let scDisplay = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(point) }) else {
                throw UICtlError.message("no display contains point (\(point.x), \(point.y))")
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let origin = filter.contentRect.origin
            let localX = Int((point.x - origin.x) * scale)
            let localY = Int((point.y - origin.y) * scale)
            return try sample(image: image, x: localX, y: localY)
        }
    }

    /// Uses NSBitmapImageRep's color accessor rather than hand-parsing the raw
    /// pixel buffer, so we don't have to guess the capture's channel order.
    private static func sample(image: CGImage, x: Int, y: Int) throws -> JSONDict {
        let rep = NSBitmapImageRep(cgImage: image)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let color = rep.colorAt(x: x, y: y) else {
            throw UICtlError.message("pixel out of bounds or unreadable")
        }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        let a = Int((rgb.alphaComponent * 255).rounded())
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        return ["r": r, "g": g, "b": b, "a": a, "hex": hex]
    }
}
