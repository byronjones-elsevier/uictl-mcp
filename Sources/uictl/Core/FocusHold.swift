import AppKit
import CoreGraphics

/// Lets an agent pin uictl to one target window so every subsequent
/// click/move/scroll/type/key call re-asserts that window's focus first —
/// countering a human's own mouse/keyboard use (e.g. clicking into the
/// terminal running uictl) stealing frontmost status away from whatever
/// uictl is mid-task automating. `hold` also snapshots whatever was
/// frontmost right before it, so `release` can put focus back there
/// afterward instead of leaving it on the automation target. Only ever
/// touched from the daemon's single accept-loop thread (see
/// `DaemonServer`), so no synchronization is needed.
enum FocusHold {
    struct Held {
        let pid: pid_t
        let windowID: CGWindowID
        let label: String
    }

    /// Outcome of a re-focus attempt (`ensureFocused` before an action, or
    /// `release`'s restore), so callers can attach it to a response instead
    /// of silently assuming the window in question actually ended up
    /// frontmost.
    enum RefocusResult: String {
        case notHeld
        case alreadyFrontmost
        case reactivated
        case failed
    }

    private static var held: Held?
    private static var previousFocus: Held?

    static func hold(windowID explicitWindowID: Int?, appSelector: String?) throws -> JSONDict {
        let resolved = try WindowResolver.resolve(windowID: explicitWindowID, appSelector: appSelector)

        // Only the first `hold` in a hold/[hold...]/release sequence
        // snapshots the pre-automation focus — re-targeting to a different
        // window without releasing in between shouldn't overwrite what
        // `release` will eventually restore.
        if held == nil {
            previousFocus = captureCurrentFocus()
        }
        held = Held(pid: resolved.pid, windowID: resolved.windowID, label: appLabel(forPID: resolved.pid))
        return status()
    }

    static func release() -> JSONDict {
        held = nil
        var result = status()
        if let previousFocus {
            result["restoredFocus"] = reactivate(previousFocus).rawValue
        }
        previousFocus = nil
        return result
    }

    static func status() -> JSONDict {
        guard let held else { return ["held": false] }
        return [
            "held": true,
            "app": held.label,
            "pid": held.pid,
            "windowId": held.windowID,
            "isFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == held.pid,
            "restoresTo": previousFocus?.label ?? NSNull(),
        ]
    }

    /// Called before every focus-sensitive action. Best-effort: if the held
    /// window has since closed (or its app has quit), this doesn't throw —
    /// a stale hold shouldn't wedge every subsequent action just because
    /// whoever set it forgot to release it.
    static func ensureFocused() -> RefocusResult {
        guard let held else { return .notHeld }
        return reactivate(held)
    }

    /// Best guess at "whatever the human/agent was looking at" right before
    /// `hold` redirects things — the frontmost app's topmost on-screen
    /// window. `nil` (rather than throwing) if there's no frontmost app or
    /// it unexpectedly has no on-screen window, since a failed snapshot
    /// shouldn't block the hold that triggered it; `release` just won't have
    /// anything to restore.
    private static func captureCurrentFocus() -> Held? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let windows = try? AppsAndWindows.listWindows(pidFilter: [frontApp.processIdentifier]),
              let topWindow = windows.first(where: { ($0["layer"] as? Int ?? 0) == 0 }),
              let windowID = topWindow["windowId"] as? Int else {
            return nil
        }
        return Held(pid: frontApp.processIdentifier, windowID: CGWindowID(windowID), label: appLabel(forPID: frontApp.processIdentifier))
    }

    private static func appLabel(forPID pid: pid_t) -> String {
        NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.localizedName ?? "pid \(pid)"
    }

    /// Best-effort: activates `target`'s app and raises its window, judging
    /// success by re-checking the actual frontmost app afterward rather than
    /// trusting `NSRunningApplication.activate`'s return value alone, since
    /// that can report success slightly ahead of the window server actually
    /// completing the switch.
    private static func reactivate(_ target: Held) -> RefocusResult {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid else { return .alreadyFrontmost }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == target.pid }) else { return .failed }

        _ = app.activate(options: [])
        try? Accessibility.raiseWindow(pid: target.pid, windowID: target.windowID)
        // Give the window server a moment to actually swap frontmost status
        // before whatever triggered this continues.
        usleep(80_000)

        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid ? .reactivated : .failed
    }
}
