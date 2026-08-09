import AppKit

enum Clipboard {
    static func get() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func set(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
