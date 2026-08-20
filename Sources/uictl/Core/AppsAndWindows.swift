import AppKit
import CoreGraphics
import ApplicationServices

enum AppsAndWindows {
    static func listApps(includeBackground: Bool) -> [JSONDict] {
        NSWorkspace.shared.runningApplications
            .filter { includeBackground || $0.activationPolicy == .regular }
            .map { app in
                [
                    "pid": app.processIdentifier,
                    "name": app.localizedName ?? "",
                    "bundleId": app.bundleIdentifier ?? "",
                    "isActive": app.isActive,
                    "isHidden": app.isHidden,
                ] as JSONDict
            }
    }

    /// Lists on-screen windows via the CGWindowList API (window metadata only —
    /// no deprecation concerns there, unlike window-image capture). `layer == 0`
    /// is the normal "app window" layer; menu bar, dock, etc. show up at other
    /// layers.
    static func listWindows(pidFilter: Set<pid_t>?) throws -> [JSONDict] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [JSONDict] else {
            throw UICtlError.message("CGWindowListCopyWindowInfo returned nothing")
        }

        return list.compactMap { entry -> JSONDict? in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? JSONDict else {
                return nil
            }
            if let pidFilter, !pidFilter.contains(ownerPID) { return nil }

            let bounds = CGRect(
                x: boundsDict["X"] as? Double ?? 0,
                y: boundsDict["Y"] as? Double ?? 0,
                width: boundsDict["Width"] as? Double ?? 0,
                height: boundsDict["Height"] as? Double ?? 0
            )
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let isOnscreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? true

            let displayID = Displays.displayID(containing: CGPoint(x: bounds.midX, y: bounds.midY))

            return [
                "windowId": windowID,
                "pid": ownerPID,
                "app": ownerName,
                "title": title,
                "layer": layer,
                "isOnscreen": isOnscreen,
                "frame": bounds.jsonDict,
                "displayId": displayID.map { Int($0) } ?? NSNull(),
            ]
        }
    }

    static func activate(appSelector: String, windowID: Int?) throws -> JSONDict {
        let app = try AppSelector.resolve(appSelector)
        guard app.activate(options: []) else {
            throw UICtlError.message("failed to activate \(app.localizedName ?? appSelector)")
        }

        if let windowID {
            try Accessibility.raiseWindow(pid: app.processIdentifier, windowID: CGWindowID(windowID))
        }

        return [
            "activated": app.localizedName ?? appSelector,
            "pid": app.processIdentifier,
        ]
    }
}
