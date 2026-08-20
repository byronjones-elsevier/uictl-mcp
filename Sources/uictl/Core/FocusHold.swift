import AppKit
import CoreGraphics

/// Lets an agent pin uictl to one target window so every subsequent
/// click/move/scroll/type/key call re-asserts that window's focus first —
/// countering a human's own mouse/keyboard use (e.g. clicking into the
/// terminal running uictl) stealing frontmost status away from whatever
/// uictl is mid-task automating. Only ever touched from the daemon's single
/// accept-loop thread (see `DaemonServer`), so no synchronization is needed.
enum FocusHold {
    struct Held {
        let pid: pid_t
        let windowID: CGWindowID
        let label: String
    }

    private static var held: Held?

    static func hold(windowID explicitWindowID: Int?, appSelector: String?) throws -> JSONDict {
        let resolved = try WindowResolver.resolve(windowID: explicitWindowID, appSelector: appSelector)
        let label = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == resolved.pid })?.localizedName ?? "pid \(resolved.pid)"
        held = Held(pid: resolved.pid, windowID: resolved.windowID, label: label)
        return status()
    }

    static func release() -> JSONDict {
        held = nil
        return status()
    }

    static func status() -> JSONDict {
        guard let held else { return ["held": false] }
        return [
            "held": true,
            "app": held.label,
            "pid": held.pid,
            "windowId": held.windowID,
            "isFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == held.pid,
        ]
    }

    /// Called before every focus-sensitive action. Best-effort: if the held
    /// window has since closed (or its app has quit), this silently gives up
    /// rather than throwing — a stale hold shouldn't wedge every subsequent
    /// action just because whoever set it forgot to release it.
    static func ensureFocused() {
        guard let held else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != held.pid else { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == held.pid }) else { return }

        app.activate(options: [])
        try? Accessibility.raiseWindow(pid: held.pid, windowID: held.windowID)
        // Give the window server a moment to actually swap frontmost status
        // before the action that triggered this fires.
        usleep(80_000)
    }
}
