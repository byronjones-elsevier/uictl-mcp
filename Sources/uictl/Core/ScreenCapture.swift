import ScreenCaptureKit
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

enum ScreenCapture {
    struct Capture {
        let image: CGImage
        /// Top-left origin of the captured region, in the same "global display"
        /// coordinate space CGWindowList/AXUIElement use (origin at the primary
        /// screen's top-left, y increasing downward).
        let origin: CGPoint
        let pointPixelScale: CGFloat
    }

    static func captureWindow(windowID: CGWindowID) throws -> Capture {
        try runSync {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                throw UICtlError.message("window \(windowID) is not capturable (closed, or Screen Recording permission not granted)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Capture(image: image, origin: scWindow.frame.origin, pointPixelScale: scale)
        }
    }

    static func captureDisplay(index: Int) throws -> Capture {
        try runSync {
            let content = try await SCShareableContent.current
            guard index >= 0, index < content.displays.count else {
                throw UICtlError.message("no display at index \(index); \(content.displays.count) display(s) available")
            }
            let display = content.displays[index]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Capture(image: image, origin: filter.contentRect.origin, pointPixelScale: scale)
        }
    }

    /// Draws a numbered box over each element's frame (converted from global
    /// screen coordinates into this capture's local pixel space) — a
    /// "set-of-marks" overlay so an LLM can say "click element 7" instead of
    /// guessing raw coordinates from a plain screenshot.
    static func annotate(_ capture: Capture, elements: [JSONDict]) -> CGImage {
        let width = capture.image.width
        let height = capture.image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return capture.image
        }

        // Flip to top-left/y-down so it matches both the image's natural
        // orientation and the coordinate space our element frames are in.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(capture.image, in: CGRect(x: 0, y: 0, width: width, height: height))

        context.setLineWidth(2)
        context.setStrokeColor(NSColor.systemRed.cgColor)

        for (index, element) in elements.enumerated() {
            guard let frameDict = element["frame"] as? JSONDict,
                  let x = frameDict["x"] as? Double, let y = frameDict["y"] as? Double,
                  let w = frameDict["w"] as? Double, let h = frameDict["h"] as? Double else { continue }

            let localRect = CGRect(
                x: (x - capture.origin.x) * capture.pointPixelScale,
                y: (y - capture.origin.y) * capture.pointPixelScale,
                width: w * capture.pointPixelScale,
                height: h * capture.pointPixelScale
            )
            context.stroke(localRect)
            drawBadge("\(index + 1)", at: CGPoint(x: localRect.minX, y: localRect.minY), in: context)
        }

        return context.makeImage() ?? capture.image
    }

    private static func drawBadge(_ text: String, at point: CGPoint, in context: CGContext) {
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.current = previous }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()
        let padding: CGFloat = 3
        let badgeRect = CGRect(x: point.x, y: point.y, width: textSize.width + padding * 2, height: textSize.height + padding * 2)

        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(badgeRect)
        attrString.draw(at: CGPoint(x: badgeRect.minX + padding, y: badgeRect.minY + padding))
    }

    static func savePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw UICtlError.message("failed to create image destination at \(path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw UICtlError.message("failed to write PNG to \(path)")
        }
    }
}
