import Foundation

/// Thread-safe mirror of the enable/disable switch in the Activity Log
/// window. `CommandDispatcher.dispatch` runs on the daemon's background
/// accept-loop thread and must never touch the switch/window directly, so
/// `ActivityWindowController` pushes state changes here (on the main thread)
/// and dispatch only ever reads the plain values cached below.
///
/// While the window is closed (or has never been opened), commands are
/// always enabled regardless of the switch's remembered position — the
/// switch only takes effect while the window is visibly open, so the state
/// can always be inspected by whoever is at the machine.
enum UICtlGate {
    private static let queue = DispatchQueue(label: "uictl.gate")
    private static var windowOpen = false
    private static var toggleEnabled = true

    static var commandsEnabled: Bool {
        queue.sync { !windowOpen || toggleEnabled }
    }

    static func setWindowOpen(_ open: Bool) {
        queue.sync { windowOpen = open }
    }

    static func setToggleEnabled(_ enabled: Bool) {
        queue.sync { toggleEnabled = enabled }
    }
}
