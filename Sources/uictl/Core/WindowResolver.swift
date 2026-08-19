import CoreGraphics
import ApplicationServices

/// Resolves the `window`/`app` params shared by screenshot, elements, and
/// wait-for into a concrete (pid, CGWindowID, frame) triple.
enum WindowResolver {
    struct Resolved {
        let pid: pid_t
        let windowID: CGWindowID
        let frame: CGRect
    }

    static func resolve(windowID explicitWindowID: Int?, appSelector: String?) throws -> Resolved {
        if let explicitWindowID {
            let id = CGWindowID(explicitWindowID)
            guard let infoArray = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [JSONDict],
                  let info = infoArray.first,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? JSONDict else {
                throw UICtlError.message("no window with id \(explicitWindowID)")
            }
            let frame = CGRect(
                x: boundsDict["X"] as? Double ?? 0, y: boundsDict["Y"] as? Double ?? 0,
                width: boundsDict["Width"] as? Double ?? 0, height: boundsDict["Height"] as? Double ?? 0
            )
            return Resolved(pid: pid, windowID: id, frame: frame)
        }

        guard let appSelector else {
            throw UICtlError.message("either \"window\" or \"app\" is required")
        }
        let app = try AppSelector.resolve(appSelector)
        let windows = try AppsAndWindows.listWindows(pidFilter: [app.processIdentifier])
            .filter { ($0["layer"] as? Int ?? 0) == 0 }
        guard let first = windows.first,
              let windowID = first["windowId"] as? Int,
              let frameDict = first["frame"] as? JSONDict else {
            throw UICtlError.message("\(app.localizedName ?? appSelector) has no on-screen windows; pass an explicit --window id from `windows` if it has a minimized/offscreen one")
        }
        let frame = CGRect(
            x: frameDict["x"] as? Double ?? 0, y: frameDict["y"] as? Double ?? 0,
            width: frameDict["w"] as? Double ?? 0, height: frameDict["h"] as? Double ?? 0
        )
        return Resolved(pid: app.processIdentifier, windowID: CGWindowID(windowID), frame: frame)
    }
}
