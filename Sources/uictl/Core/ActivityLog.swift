import Foundation

struct ActivityEntry {
    let timestamp: Date
    let command: String
    let paramsSummary: String
    let responseSummary: String
    let ok: Bool
    let durationMs: Double
}

/// Records every CLI/MCP call the daemon handles, so a human watching this
/// machine can see what's being automated (`uictl log show`) and an agent can
/// export an audit trail (`uictl log export`). Capped at `maxEntries` (oldest
/// dropped first) since this lives for the daemon's whole lifetime.
final class ActivityLog {
    static let shared = ActivityLog()

    private let queue = DispatchQueue(label: "uictl.activitylog")
    private var entries: [ActivityEntry] = []
    private let maxEntries = 2000

    /// Invoked on the main thread after every record — wired up once at
    /// daemon startup by the GUI layer (toast + log window), so this type
    /// itself has no AppKit dependency.
    var onRecord: ((ActivityEntry) -> Void)?

    private init() {}

    func record(command: String, params: JSONDict, response: JSONDict, durationMs: Double) {
        let entry = ActivityEntry(
            timestamp: Date(),
            command: command,
            paramsSummary: Self.summarizeParams(command: command, params: params),
            responseSummary: Self.summarizeResponse(command: command, response: response),
            ok: (response["ok"] as? Bool) ?? false,
            durationMs: durationMs
        )
        queue.sync {
            entries.append(entry)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
        }
        if let onRecord {
            DispatchQueue.main.async { onRecord(entry) }
        }
    }

    func snapshot() -> [ActivityEntry] {
        queue.sync { entries }
    }

    func exportJSON(to path: String) throws {
        let formatter = ISO8601DateFormatter()
        let records = snapshot().map { entry -> JSONDict in
            [
                "timestamp": formatter.string(from: entry.timestamp),
                "command": entry.command,
                "params": entry.paramsSummary,
                "response": entry.responseSummary,
                "ok": entry.ok,
                "durationMs": entry.durationMs,
            ]
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Redacts `"text"` to a length placeholder for commands that type or set
    /// the clipboard — that's the one param shape likely to carry something
    /// sensitive (a password typed into a field, secret clipboard content),
    /// and this log is both on-screen and exportable to a file.
    ///
    /// Deliberately not redacted: `ocr`/`elements`/`screenshot` output, whose
    /// entire purpose is reading whatever's genuinely on screen — which can
    /// include sensitive text an automated app happens to display. See the
    /// "Security note" in ENGINEERING.md's "Activity log window" section
    /// before treating the log window, its exports, or saved screenshots as
    /// safe to leave lying around.
    private static func summarizeParams(command: String, params: JSONDict) -> String {
        var redacted = params
        if command == "type" || command == "clipboard.set", let text = redacted["text"] as? String {
            redacted["text"] = "<\(text.count) chars>"
        }
        return jsonSummary(redacted)
    }

    /// Same redaction, mirrored for the one response shape that returns
    /// clipboard content back out (`clipboard.get`). Shows just the payload
    /// (`"data"`/`"error"`) — `"ok"` is already its own column.
    private static func summarizeResponse(command: String, response: JSONDict) -> String {
        var redacted = response
        if command == "clipboard.get", var data = redacted["data"] as? JSONDict, let text = data["text"] as? String {
            data["text"] = "<\(text.count) chars>"
            redacted["data"] = data
        }
        return jsonSummary(redacted["data"] ?? redacted["error"] ?? NSNull())
    }

    /// JSON-encodes `obj` (which may be a bare fragment — string, number,
    /// null — not just an array/dictionary) for display/export, truncated to
    /// a sane length.
    private static func jsonSummary(_ obj: Any) -> String {
        let limit = 4000
        let str: String
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed]),
           let decoded = String(data: data, encoding: .utf8) {
            str = decoded
        } else {
            str = "\(obj)"
        }
        return str.count > limit ? String(str.prefix(limit)) + "…" : str
    }
}
