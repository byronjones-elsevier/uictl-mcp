import Foundation
import CoreGraphics
import ApplicationServices

/// Every request the daemon receives — whether it arrived from a CLI
/// subcommand or an MCP tool call — funnels through here. Keeping this as one
/// switch (rather than scattering dispatch logic across command types) means
/// the CLI and MCP front ends can stay as thin, dumb translators.
enum CommandDispatcher {
    static func dispatch(command: String, params: JSONDict) -> JSONDict {
        do {
            switch command {
            case "permissions.status":
                return successResponse(Permissions.status())
            case "permissions.request":
                Permissions.request()
                return successResponse(Permissions.status())

            case "apps.list":
                return successResponse(AppsAndWindows.listApps(includeBackground: params["all"] as? Bool ?? false))

            case "windows.list":
                let pids: Set<pid_t>? = try (params["app"] as? String).map { selector in
                    Set(try AppSelector.resolveAll(selector).map(\.processIdentifier))
                }
                return successResponse(try AppsAndWindows.listWindows(pidFilter: pids))

            case "activate":
                guard let appSelector = params["app"] as? String else {
                    throw UICtlError.message("\"app\" is required")
                }
                return successResponse(try AppsAndWindows.activate(appSelector: appSelector, windowID: params["window"] as? Int))

            case "screenshot":
                return try runScreenshot(params)

            case "elements":
                return try runElements(params)

            case "click":
                return try runClick(params)

            case "move":
                guard let atText = params["at"] as? String else { throw UICtlError.message("\"at\" is required") }
                try InputSynthesis.move(to: try parsePoint(atText))
                return successResponse(["moved": true])

            case "scroll":
                guard let atText = params["at"] as? String else { throw UICtlError.message("\"at\" is required") }
                let point = try parsePoint(atText)
                let dx = Int32(params["dx"] as? Int ?? 0)
                let dy = Int32(params["dy"] as? Int ?? 0)
                try InputSynthesis.scroll(at: point, dx: dx, dy: dy)
                return successResponse(["scrolled": true])

            case "type":
                return try runType(params)

            case "key":
                guard let combo = params["combo"] as? String else { throw UICtlError.message("\"combo\" is required") }
                try InputSynthesis.sendKeyCombo(combo)
                return successResponse(["sent": combo])

            case "waitFor":
                return try runWaitFor(params)

            case "ocr":
                return try runOCR(params)

            case "clipboard.get":
                return successResponse(["text": Clipboard.get() ?? ""])

            case "clipboard.set":
                guard let text = params["text"] as? String else { throw UICtlError.message("\"text\" is required") }
                Clipboard.set(text)
                return successResponse(["set": true])

            case "pixel":
                guard let atText = params["at"] as? String else { throw UICtlError.message("\"at\" is required") }
                return successResponse(try PixelSampler.colorAt(point: try parsePoint(atText)))

            default:
                return errorResponse("unknown command \"\(command)\"")
            }
        } catch {
            return errorResponse("\(error)")
        }
    }

    // MARK: - Screenshot

    private static func runScreenshot(_ params: JSONDict) throws -> JSONDict {
        let annotate = params["annotate"] as? Bool ?? false
        let outPath = (params["out"] as? String) ?? defaultScreenshotPath()

        let capture: ScreenCapture.Capture
        var elements: [JSONDict] = []

        if let screenIndex = params["screen"] as? Int {
            capture = try ScreenCapture.captureDisplay(index: screenIndex)
        } else {
            let resolved = try WindowResolver.resolve(windowID: params["window"] as? Int, appSelector: params["app"] as? String)
            capture = try ScreenCapture.captureWindow(windowID: resolved.windowID)
            if annotate {
                let windowElement = try Accessibility.resolveWindowElement(pid: resolved.pid, windowID: resolved.windowID)
                let options = Accessibility.WalkOptions(
                    roleFilter: params["role"] as? String, titleContains: nil, maxDepth: 25, maxElements: 200
                )
                (elements, _) = Accessibility.enumerateElements(windowID: resolved.windowID, windowElement: windowElement, options: options)
            }
        }

        let finalImage = annotate ? ScreenCapture.annotate(capture, elements: elements) : capture.image
        try ScreenCapture.savePNG(finalImage, to: outPath)

        var data: JSONDict = [
            "path": outPath,
            "width": finalImage.width,
            "height": finalImage.height,
        ]
        if annotate {
            data["elements"] = elements.enumerated().map { index, element -> JSONDict in
                var withNumber = element
                withNumber["number"] = index + 1
                return withNumber
            }
        }
        return successResponse(data)
    }

    private static func defaultScreenshotPath() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return UICtlPaths.homeDir + "/screenshots/\(stamp).png"
    }

    // MARK: - Elements

    private static func runElements(_ params: JSONDict) throws -> JSONDict {
        let resolved = try WindowResolver.resolve(windowID: params["window"] as? Int, appSelector: params["app"] as? String)
        let windowElement = try Accessibility.resolveWindowElement(pid: resolved.pid, windowID: resolved.windowID)
        let options = Accessibility.WalkOptions(
            roleFilter: params["role"] as? String,
            titleContains: params["title"] as? String,
            maxDepth: params["maxDepth"] as? Int ?? 25,
            maxElements: params["maxElements"] as? Int ?? 500
        )
        let (elements, truncated) = Accessibility.enumerateElements(windowID: resolved.windowID, windowElement: windowElement, options: options)
        var data: JSONDict = ["windowId": resolved.windowID, "count": elements.count, "elements": elements]
        if truncated { data["truncated"] = true }
        return successResponse(data)
    }

    // MARK: - Click / Type

    private static func runClick(_ params: JSONDict) throws -> JSONDict {
        let point: CGPoint
        var axElement: AXUIElement?

        if let elementID = params["element"] as? String {
            let element = try Accessibility.lookupElement(elementID: elementID)
            guard let elementFrame = Accessibility.frame(of: element) else {
                throw UICtlError.message("element \"\(elementID)\" no longer has a frame")
            }
            let enabled: Bool = Accessibility.attribute(element, kAXEnabledAttribute) ?? true
            guard enabled else {
                throw UICtlError.message("element \"\(elementID)\" is disabled (AXEnabled=false); refusing to click")
            }
            axElement = element
            point = elementFrame.center
        } else if let atText = params["at"] as? String {
            point = try parsePoint(atText)
        } else {
            throw UICtlError.message("either \"at\" or \"element\" is required")
        }

        let buttonName = (params["button"] as? String ?? "left").lowercased()
        let button: CGMouseButton = buttonName == "right" ? .right : (buttonName == "center" ? .center : .left)
        let count = (params["double"] as? Bool == true) ? 2 : (params["count"] as? Int ?? 1)

        let before = axElement.map(ClickVerificationSnapshot.init)
        try InputSynthesis.click(at: point, button: button, clickCount: count)

        var data: JSONDict = ["clicked": point.jsonDict]
        if let axElement, let before {
            usleep(40_000)
            let after = ClickVerificationSnapshot(element: axElement)
            if let changed = before.changed(comparedTo: after) {
                data["verification"] = changed ? "changed" : "unchanged"
            } else {
                // Fully custom-drawn/webview elements typically expose neither
                // AXValue nor AXSelected, so there's nothing here to diff —
                // say so explicitly rather than implying the click was verified.
                data["verification"] = "unavailable"
            }
        }
        return successResponse(data)
    }

    private static func runType(_ params: JSONDict) throws -> JSONDict {
        guard let text = params["text"] as? String else { throw UICtlError.message("\"text\" is required") }

        if let elementID = params["element"] as? String {
            if try Accessibility.trySetValue(elementID: elementID, text: text) {
                return successResponse(["method": "axValue", "element": elementID])
            }
            try Accessibility.setFocus(elementID: elementID)
            usleep(50_000)
            try InputSynthesis.typeText(text)
            return successResponse(["method": "synthesizedKeystrokes", "element": elementID])
        }

        try InputSynthesis.typeText(text)
        return successResponse(["method": "synthesizedKeystrokes"])
    }

    // MARK: - Wait for element

    private static func runWaitFor(_ params: JSONDict) throws -> JSONDict {
        let resolved = try WindowResolver.resolve(windowID: params["window"] as? Int, appSelector: params["app"] as? String)
        let timeout = params["timeout"] as? Double ?? 10
        let deadline = Date().addingTimeInterval(timeout)
        let options = Accessibility.WalkOptions(
            roleFilter: params["role"] as? String, titleContains: params["title"] as? String, maxDepth: 25, maxElements: 1
        )

        while Date() < deadline {
            let windowElement = try Accessibility.resolveWindowElement(pid: resolved.pid, windowID: resolved.windowID)
            let (matches, _) = Accessibility.enumerateElements(windowID: resolved.windowID, windowElement: windowElement, options: options)
            if let match = matches.first {
                return successResponse(["found": true, "element": match])
            }
            usleep(200_000)
        }
        return successResponse(["found": false])
    }

    // MARK: - OCR

    private static func runOCR(_ params: JSONDict) throws -> JSONDict {
        let region = try (params["region"] as? String).map { try parseRect($0) }

        if let imagePath = params["image"] as? String {
            guard let provider = CGDataProvider(filename: imagePath),
                  let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw UICtlError.message("could not load PNG at \(imagePath)")
            }
            let results = try OCR.recognizeText(in: image, region: region, imageOrigin: .zero, scale: 1)
            return successResponse(["textBlocks": results])
        }

        let resolved = try WindowResolver.resolve(windowID: params["window"] as? Int, appSelector: params["app"] as? String)
        let capture = try ScreenCapture.captureWindow(windowID: resolved.windowID)
        let results = try OCR.recognizeText(in: capture.image, region: region, imageOrigin: capture.origin, scale: capture.pointPixelScale)
        return successResponse(["textBlocks": results])
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Best-effort AX state to diff before/after a click, so `runClick` can
/// report whether anything observably changed instead of always claiming
/// success once the CGEvent posted. `nil` from `changed` means the element
/// exposed neither attribute — most commonly a custom-drawn/webview control,
/// which is exactly the case with no reliable signal today.
private struct ClickVerificationSnapshot {
    let value: String?
    let selected: Bool?

    init(element: AXUIElement) {
        value = Accessibility.stringValue(of: element)
        selected = Accessibility.attribute(element, kAXSelectedAttribute)
    }

    func changed(comparedTo after: ClickVerificationSnapshot) -> Bool? {
        guard value != nil || selected != nil else { return nil }
        return value != after.value || selected != after.selected
    }
}
