import CoreGraphics
import Foundation

enum InputSynthesis {
    static func click(at point: CGPoint, button: CGMouseButton, clickCount: Int) throws {
        let (downType, upType): (CGEventType, CGEventType)
        switch button {
        case .left: (downType, upType) = (.leftMouseDown, .leftMouseUp)
        case .right: (downType, upType) = (.rightMouseDown, .rightMouseUp)
        default: (downType, upType) = (.otherMouseDown, .otherMouseUp)
        }

        for clickIndex in 1...max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                throw UICtlError.message("failed to create mouse event")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down.post(tap: .cghidEventTap)
            usleep(10_000)
            up.post(tap: .cghidEventTap)
            if clickIndex < clickCount { usleep(50_000) }
        }
    }

    static func move(to point: CGPoint) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw UICtlError.message("failed to create mouse-move event")
        }
        event.post(tap: .cghidEventTap)
    }

    static func scroll(at point: CGPoint, dx: Int32, dy: Int32) throws {
        CGWarpMouseCursorPosition(point)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw UICtlError.message("failed to create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    /// Sends each character as its own key down/up pair carrying a raw Unicode
    /// payload, bypassing keycode/layout mapping entirely — works for any
    /// Unicode text (including emoji and non-Latin scripts), which a
    /// keycode-based approach cannot do.
    static func typeText(_ text: String) throws {
        for character in text {
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw UICtlError.message("failed to create keyboard event")
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    /// Sends a chorded shortcut like "cmd+shift+4" or "ctrl+alt+delete".
    static func sendKeyCombo(_ combo: String) throws {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let keyPart = parts.last else {
            throw UICtlError.message("empty key combo")
        }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw UICtlError.message("unknown modifier \"\(modifier)\" in combo \"\(combo)\"")
            }
        }
        guard let keyCode = KeyCodeTable.codes[keyPart] else {
            throw UICtlError.message("unknown key \"\(keyPart)\" in combo \"\(combo)\"")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw UICtlError.message("failed to create keyboard event")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
    }
}

/// US-layout virtual keycodes (the standard kVK_* constants from HIToolbox),
/// reproduced here to avoid pulling in the Carbon framework for a handful of
/// integers.
enum KeyCodeTable {
    static let codes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "enter": 0x24, "l": 0x25, "j": 0x26,
        "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
        ".": 0x2F, "tab": 0x30, "space": 0x31, "`": 0x32, "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "forwarddelete": 0x75,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]
}
