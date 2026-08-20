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

    /// Outcome of `ensureFocused()`, so callers can attach it to the JSON
    /// response of whatever action triggered it instead of silently assuming
    /// the click/type/key that follows landed on the intended window.
    enum RefocusResult: String {
        case notHeld
        case alreadyFrontmost
        case reactivated
        case failed
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
    /// window has since closed (or its app has quit) or activation fails
    /// outright, this doesn't throw — a stale/failed hold shouldn't wedge
    /// every subsequent action just because whoever set it forgot to release
    /// it. Success is judged by re-checking the actual frontmost app after
    /// the attempt rather than trusting `NSRunningApplication.activate`'s
    /// return value alone, since that can report success slightly ahead of
    /// the window server actually completing the switch.
    static func ensureFocused() -> RefocusResult {
        guard let held else { return .notHeld }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != held.pid else { return .alreadyFrontmost }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == held.pid }) else { return .failed }

        _ = app.activate(options: [])
        try? Accessibility.raiseWindow(pid: held.pid, windowID: held.windowID)
        // Give the window server a moment to actually swap frontmost status
        // before the action that triggered this fires.
        usleep(80_000)

        return NSWorkspace.shared.frontmostApplication?.processIdentifier == held.pid ? .reactivated : .failed
    }
}
