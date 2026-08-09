import ApplicationServices
import CoreGraphics
import Foundation

enum Accessibility {
    // MARK: - Attribute helpers

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    static func stringValue(of element: AXUIElement) -> String? {
        if let s: String = attribute(element, kAXValueAttribute) { return s }
        if let n: NSNumber = attribute(element, kAXValueAttribute) { return n.stringValue }
        return nil
    }

    // MARK: - Window resolution

    /// There is no public API mapping a CGWindowID directly to an AXUIElement,
    /// so this matches by title + frame against the app's kAXWindowsAttribute
    /// list — the standard approach used by most macOS UI-automation tools.
    static func resolveWindowElement(pid: pid_t, windowID: CGWindowID) throws -> AXUIElement {
        guard let cgInfoArray = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [JSONDict],
              let cgInfo = cgInfoArray.first else {
            throw UICtlError.message("no window with id \(windowID)")
        }
        let cgTitle = cgInfo[kCGWindowName as String] as? String ?? ""
        let boundsDict = cgInfo[kCGWindowBounds as String] as? JSONDict ?? [:]
        let cgBounds = CGRect(
            x: boundsDict["X"] as? Double ?? 0,
            y: boundsDict["Y"] as? Double ?? 0,
            width: boundsDict["Width"] as? Double ?? 0,
            height: boundsDict["Height"] as? Double ?? 0
        )

        let appElement = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute), !windows.isEmpty else {
            throw UICtlError.message("app (pid \(pid)) exposes no accessibility windows")
        }
        if windows.count == 1 { return windows[0] }

        if !cgTitle.isEmpty {
            let titleMatches = windows.filter { (attribute($0, kAXTitleAttribute) as String?) == cgTitle }
            if titleMatches.count == 1 { return titleMatches[0] }
            if titleMatches.count > 1 {
                if let byFrame = titleMatches.first(where: { frame(of: $0)?.approximatelyEquals(cgBounds) ?? false }) {
                    return byFrame
                }
                return titleMatches[0]
            }
        }

        if let byFrame = windows.first(where: { frame(of: $0)?.approximatelyEquals(cgBounds) ?? false }) {
            return byFrame
        }

        throw UICtlError.message("could not correlate window id \(windowID) to an accessibility element")
    }

    static func raiseWindow(pid: pid_t, windowID: CGWindowID) throws {
        let windowElement = try resolveWindowElement(pid: pid, windowID: windowID)
        AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
    }

    // MARK: - Tree walk

    struct WalkOptions {
        var roleFilter: String?
        var titleContains: String?
        var maxDepth: Int
        var maxElements: Int
    }

    /// Walks the accessibility tree under `windowElement`, registers every
    /// element with a resolvable on-screen frame into the ElementStore, and
    /// returns their JSON descriptions. Returns (elements, truncated).
    static func enumerateElements(windowID: CGWindowID, windowElement: AXUIElement, options: WalkOptions) -> ([JSONDict], Bool) {
        ElementStore.shared.reset(windowID: windowID)
        var results: [JSONDict] = []
        var truncated = false

        func visit(_ element: AXUIElement, depth: Int) {
            if truncated || depth > options.maxDepth { return }

            let role: String = attribute(element, kAXRoleAttribute) ?? "unknown"
            let elementFrame = frame(of: element)

            if let elementFrame, elementFrame.width > 0, elementFrame.height > 0 {
                let title: String = attribute(element, kAXTitleAttribute) ?? ""
                let description: String = attribute(element, kAXDescriptionAttribute) ?? ""
                let label = title.isEmpty ? description : title
                let matchesRole = options.roleFilter.map { $0.caseInsensitiveCompare(role) == .orderedSame } ?? true
                let matchesTitle = options.titleContains.map {
                    label.range(of: $0, options: .caseInsensitive) != nil
                } ?? true

                if matchesRole && matchesTitle {
                    if results.count >= options.maxElements {
                        truncated = true
                        return
                    }
                    let id = ElementStore.shared.register(windowID: windowID, element: element)
                    let enabled: Bool = attribute(element, kAXEnabledAttribute) ?? true
                    let focused: Bool = attribute(element, kAXFocusedAttribute) ?? false
                    var dict: JSONDict = [
                        "id": id,
                        "role": role,
                        "title": label,
                        "enabled": enabled,
                        "focused": focused,
                        "frame": elementFrame.jsonDict,
                    ]
                    if let value = stringValue(of: element) { dict["value"] = value }
                    results.append(dict)
                }
            }

            if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
                for child in children {
                    visit(child, depth: depth + 1)
                    if truncated { return }
                }
            }
        }

        visit(windowElement, depth: 0)
        return (results, truncated)
    }

    // MARK: - Interaction

    static func lookupFrame(elementID: String) throws -> CGRect {
        guard let element = ElementStore.shared.lookup(elementID) else {
            throw UICtlError.message("unknown element id \"\(elementID)\" — run `elements` again, ids are invalidated whenever a window is re-listed")
        }
        guard let elementFrame = frame(of: element) else {
            throw UICtlError.message("element \"\(elementID)\" no longer has a frame")
        }
        return elementFrame
    }

    /// Tries the fast path of setting AXValue directly (works for standard
    /// text fields); returns false if the attribute isn't settable so the
    /// caller can fall back to focus-and-type.
    static func trySetValue(elementID: String, text: String) throws -> Bool {
        guard let element = ElementStore.shared.lookup(elementID) else {
            throw UICtlError.message("unknown element id \"\(elementID)\"")
        }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        return result == .success
    }

    static func setFocus(elementID: String) throws {
        guard let element = ElementStore.shared.lookup(elementID) else {
            throw UICtlError.message("unknown element id \"\(elementID)\"")
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }
}
