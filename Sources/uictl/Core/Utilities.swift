import Foundation

typealias JSONDict = [String: Any]

enum UICtlError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let m): return m
        }
    }
}

func successResponse(_ data: Any) -> JSONDict {
    ["ok": true, "data": data]
}

func errorResponse(_ message: String) -> JSONDict {
    ["ok": false, "error": message]
}

func jsonString(_ obj: Any, pretty: Bool = true) -> String {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: options),
          let str = String(data: data, encoding: .utf8) else {
        return "{\"ok\":false,\"error\":\"failed to encode response\"}"
    }
    return str
}

/// Prints a daemon-style response dictionary to stdout as JSON and exits with a
/// status code that reflects the "ok" field, so shell scripting (`&&`, `if`) works.
func emit(_ response: JSONDict) -> Never {
    print(jsonString(response))
    let ok = (response["ok"] as? Bool) ?? false
    exit(ok ? 0 : 1)
}

/// Parses "x,y" into a CGPoint, or throws.
func parsePoint(_ text: String) throws -> CGPoint {
    let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
        throw UICtlError.message("expected \"x,y\", got \"\(text)\"")
    }
    return CGPoint(x: x, y: y)
}

/// Parses "x,y,w,h" into a CGRect, or throws.
func parseRect(_ text: String) throws -> CGRect {
    let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 4, let x = Double(parts[0]), let y = Double(parts[1]),
          let w = Double(parts[2]), let h = Double(parts[3]) else {
        throw UICtlError.message("expected \"x,y,w,h\", got \"\(text)\"")
    }
    return CGRect(x: x, y: y, width: w, height: h)
}

extension CGRect {
    var jsonDict: JSONDict {
        ["x": origin.x, "y": origin.y, "w": size.width, "h": size.height]
    }
}

extension CGPoint {
    var jsonDict: JSONDict {
        ["x": x, "y": y]
    }
}
