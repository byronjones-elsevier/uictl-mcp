import MCP
import Foundation

/// Exposes every uictl capability as an MCP tool over stdio. Each tool handler
/// is a thin translator that forwards to the same daemon `CommandDispatcher`
/// the CLI subcommands use, via `DaemonClient` — so element ids, the running
/// daemon, and its permission grants are shared identically whether a caller
/// drives uictl through the CLI or through MCP.
enum MCPServer {
    static func run() async throws {
        let server = Server(
            name: "uictl",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions.map(\.tool))
        }

        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments?.mapValues(anyFromValue) ?? [:]
            guard let spec = toolDefinitions.first(where: { $0.tool.name == params.name }) else {
                return .init(content: [.text(text: jsonString(errorResponse("unknown tool \(params.name)")), annotations: nil, _meta: nil)], isError: true)
            }
            let response = DaemonClient.send(command: spec.command, params: args)
            let ok = (response["ok"] as? Bool) ?? false
            return .init(content: [.text(text: jsonString(response), annotations: nil, _meta: nil)], isError: !ok)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        // Keep the process alive for the lifetime of the stdio session.
        await server.waitUntilCompleted()
    }
}

private func anyFromValue(_ value: Value) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .data(_, let d): return d
    case .array(let arr): return arr.map(anyFromValue)
    case .object(let obj): return obj.mapValues(anyFromValue)
    }
}

private func prop(_ type: String, _ description: String) -> Value {
    .object(["type": .string(type), "description": .string(description)])
}

private func schema(_ properties: [String: Value], required: [String] = []) -> Value {
    .object([
        "type": "object",
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
    ])
}

private struct ToolSpec {
    let command: String
    let tool: Tool
}

private let toolDefinitions: [ToolSpec] = [
    ToolSpec(
        command: "apps.list",
        tool: Tool(name: "uictl_apps", description: "List running applications.",
                   inputSchema: schema(["all": prop("boolean", "Include background/agent apps.")]))
    ),
    ToolSpec(
        command: "windows.list",
        tool: Tool(name: "uictl_windows", description: "List on-screen windows, optionally filtered to one app.",
                   inputSchema: schema(["app": prop("string", "Name substring, bundle id, or pid.")]))
    ),
    ToolSpec(
        command: "activate",
        tool: Tool(name: "uictl_activate", description: "Bring an application (and optionally a specific window) to the front.",
                   inputSchema: schema([
                       "app": prop("string", "Name substring, bundle id, or pid."),
                       "window": prop("integer", "Window id to also raise."),
                   ], required: ["app"]))
    ),
    ToolSpec(
        command: "screenshot",
        tool: Tool(name: "uictl_screenshot",
                   description: "Capture a window, an app's frontmost window, or a display. Set annotate=true to overlay numbered boxes on every accessibility element and get a legend back — then click/type by element number.",
                   inputSchema: schema([
                       "window": prop("integer", "Window id (from uictl_windows)."),
                       "app": prop("string", "App whose frontmost window to capture."),
                       "screen": prop("integer", "Display index to capture instead of a window."),
                       "out": prop("string", "Output PNG path. Defaults under ~/.uictl/screenshots/."),
                       "annotate": prop("boolean", "Overlay numbered element boxes and return a legend."),
                       "role": prop("string", "When annotating, only include elements with this AXRole."),
                   ]))
    ),
    ToolSpec(
        command: "elements",
        tool: Tool(name: "uictl_elements",
                   description: "Walk a window's accessibility tree; returns each element's id, role, title, value, and frame.",
                   inputSchema: schema([
                       "window": prop("integer", "Window id (from uictl_windows)."),
                       "app": prop("string", "App whose frontmost window to inspect."),
                       "role": prop("string", "Only include elements with this AXRole."),
                       "title": prop("string", "Only include elements whose title/description contains this."),
                       "maxDepth": prop("integer", "Maximum tree depth."),
                       "maxElements": prop("integer", "Stop after this many matches."),
                   ]))
    ),
    ToolSpec(
        command: "click",
        tool: Tool(name: "uictl_click", description: "Click at a screen point or on a specific element (by id from uictl_elements/uictl_screenshot).",
                   inputSchema: schema([
                       "at": prop("string", "\"x,y\" screen point."),
                       "element": prop("string", "Element id."),
                       "button": prop("string", "left | right | center"),
                       "double": prop("boolean", "Double-click."),
                       "count": prop("integer", "Click count (e.g. 3 for triple-click)."),
                   ]))
    ),
    ToolSpec(
        command: "move",
        tool: Tool(name: "uictl_move", description: "Move the mouse cursor without clicking.",
                   inputSchema: schema(["at": prop("string", "\"x,y\" screen point.")], required: ["at"]))
    ),
    ToolSpec(
        command: "scroll",
        tool: Tool(name: "uictl_scroll", description: "Scroll at a screen point.",
                   inputSchema: schema([
                       "at": prop("string", "\"x,y\" screen point."),
                       "dx": prop("integer", "Horizontal delta (positive scrolls left)."),
                       "dy": prop("integer", "Vertical delta (positive scrolls up)."),
                   ], required: ["at"]))
    ),
    ToolSpec(
        command: "type",
        tool: Tool(name: "uictl_type",
                   description: "Type text into the focused control, or into a specific element by id (tries setting its value directly, falls back to focus + synthesized keystrokes).",
                   inputSchema: schema([
                       "text": prop("string", "Text to type."),
                       "element": prop("string", "Element id to type into."),
                   ], required: ["text"]))
    ),
    ToolSpec(
        command: "key",
        tool: Tool(name: "uictl_key", description: "Send a keyboard shortcut, e.g. \"cmd+shift+4\".",
                   inputSchema: schema(["combo": prop("string", "Modifiers joined with +: cmd, shift, alt/option, ctrl/control, fn.")], required: ["combo"]))
    ),
    ToolSpec(
        command: "waitFor",
        tool: Tool(name: "uictl_wait_for", description: "Block until an element matching role/title appears in a window, or timeout elapses.",
                   inputSchema: schema([
                       "window": prop("integer", "Window id."),
                       "app": prop("string", "App whose frontmost window to watch."),
                       "role": prop("string", "AXRole to match."),
                       "title": prop("string", "Title/description substring to match."),
                       "timeout": prop("number", "Seconds to wait (default 10)."),
                   ]))
    ),
    ToolSpec(
        command: "ocr",
        tool: Tool(name: "uictl_ocr", description: "Recognize text in an image file or a window, optionally restricted to a region.",
                   inputSchema: schema([
                       "image": prop("string", "PNG path, instead of capturing a window."),
                       "window": prop("integer", "Window id to capture and OCR."),
                       "app": prop("string", "App whose frontmost window to capture and OCR."),
                       "region": prop("string", "\"x,y,w,h\" to restrict OCR to."),
                   ]))
    ),
    ToolSpec(
        command: "pixel",
        tool: Tool(name: "uictl_pixel", description: "Sample the color of a single screen pixel.",
                   inputSchema: schema(["at": prop("string", "\"x,y\" screen point.")], required: ["at"]))
    ),
    ToolSpec(
        command: "clipboard.get",
        tool: Tool(name: "uictl_clipboard_get", description: "Read the system clipboard text.", inputSchema: schema([:]))
    ),
    ToolSpec(
        command: "clipboard.set",
        tool: Tool(name: "uictl_clipboard_set", description: "Write text to the system clipboard.",
                   inputSchema: schema(["text": prop("string", "Text to place on the clipboard.")], required: ["text"]))
    ),
    ToolSpec(
        command: "permissions.status",
        tool: Tool(name: "uictl_permissions", description: "Check Accessibility and Screen Recording permission status.", inputSchema: schema([:]))
    ),
]
