import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the OS permission prompts (a no-op if already granted/denied
    /// previously — macOS only prompts once per app, after that the user must
    /// use System Settings).
    static func request() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }

    static func status() -> JSONDict {
        [
            "accessibility": accessibilityTrusted(),
            "screenRecording": screenRecordingGranted(),
            "hint": accessibilityTrusted() && screenRecordingGranted()
                ? "all required permissions granted"
                : "grant via System Settings > Privacy & Security > Accessibility / Screen Recording for the terminal app (or process) running uictl; run `uictl permissions --request` to trigger the prompts",
        ]
    }
}
