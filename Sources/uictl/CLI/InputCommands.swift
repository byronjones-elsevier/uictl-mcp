import ArgumentParser

struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click at a screen point or on a specific element.")

    @Option(help: "Screen point to click: \"x,y\". Relative to --window/--app's top-left corner if either is given, otherwise an absolute global-screen point.")
    var at: String?

    @Option(help: "Element id (from `elements` or `screenshot --annotate`) to click the center of.")
    var element: String?

    @Option(help: "Treat --at as relative to this window's current top-left corner (from `windows`) instead of an absolute screen point.")
    var window: Int?

    @Option(help: "Treat --at as relative to this app's frontmost window's current top-left corner instead of an absolute screen point.")
    var app: String?

    @Option(help: "Mouse button.")
    var button: String = "left"

    @Flag(help: "Double-click instead of single-click.")
    var double = false

    @Option(help: "Click count (e.g. 3 for triple-click). Ignored if --double is set.")
    var count: Int?

    @Flag(help: "Leave the cursor at the click point instead of restoring it to where it was before the click (e.g. to keep a hover-dependent tooltip/menu open for a follow-up screenshot).")
    var hoverCursor = false

    func run() throws {
        var params: JSONDict = ["button": button, "double": double, "hoverCursor": hoverCursor]
        if let at { params["at"] = at }
        if let element { params["element"] = element }
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        if let count { params["count"] = count }
        emit(DaemonClient.send(command: "click", params: params))
    }
}

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move the mouse cursor without clicking (e.g. to trigger hover states).")

    @Option(help: "Screen point to move to: \"x,y\". Relative to --window/--app's top-left corner if either is given, otherwise an absolute global-screen point.")
    var at: String

    @Option(help: "Treat --at as relative to this window's current top-left corner (from `windows`) instead of an absolute screen point.")
    var window: Int?

    @Option(help: "Treat --at as relative to this app's frontmost window's current top-left corner instead of an absolute screen point.")
    var app: String?

    func run() throws {
        var params: JSONDict = ["at": at]
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        emit(DaemonClient.send(command: "move", params: params))
    }
}

struct ScrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll at a screen point.")

    @Option(help: "Screen point to scroll at: \"x,y\". Relative to --window/--app's top-left corner if either is given, otherwise an absolute global-screen point.")
    var at: String

    @Option(help: "Treat --at as relative to this window's current top-left corner (from `windows`) instead of an absolute screen point.")
    var window: Int?

    @Option(help: "Treat --at as relative to this app's frontmost window's current top-left corner instead of an absolute screen point.")
    var app: String?

    @Option(help: "Vertical scroll delta in pixels (positive scrolls up).")
    var dy: Int = 0

    @Option(help: "Horizontal scroll delta in pixels (positive scrolls left).")
    var dx: Int = 0

    func run() throws {
        var params: JSONDict = ["at": at, "dx": dx, "dy": dy]
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        emit(DaemonClient.send(command: "scroll", params: params))
    }
}

struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused control, or into a specific element.",
        discussion: """
        With --element, tries to set the element's value directly first (fast, \
        reliable for standard text fields); if the element doesn't support that, \
        falls back to focusing it and synthesizing keystrokes. Without --element, \
        keystrokes go to whatever currently has keyboard focus.
        """
    )

    @Argument(help: "Text to type.")
    var text: String

    @Option(help: "Element id (from `elements`) to type into.")
    var element: String?

    func run() throws {
        var params: JSONDict = ["text": text]
        if let element { params["element"] = element }
        emit(DaemonClient.send(command: "type", params: params))
    }
}

struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Send a keyboard shortcut, e.g. \"cmd+shift+4\" or \"ctrl+alt+delete\"."
    )

    @Argument(help: "Key combo, modifiers joined with \"+\": cmd, shift, alt/option, ctrl/control, fn.")
    var combo: String

    func run() throws {
        emit(DaemonClient.send(command: "key", params: ["combo": combo]))
    }
}
