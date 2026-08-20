import Foundation

/// Wires the toast and log window up to every recorded call. Called once at
/// daemon startup, before the accept loop starts and before `NSApp.run()`.
enum ActivityUI {
    static func install() {
        ActivityLog.shared.onRecord = { entry in
            ToastController.shared.show(for: entry)
            ActivityWindowController.shared.append(entry)
        }
    }
}
