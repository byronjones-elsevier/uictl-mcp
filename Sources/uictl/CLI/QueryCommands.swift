import ArgumentParser

struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Check (and optionally trigger the OS prompts for) Accessibility and Screen Recording permissions."
    )

    @Flag(help: "Trigger the system permission prompts if not yet granted or denied.")
    var request = false

    func run() throws {
        emit(DaemonClient.send(command: request ? "permissions.request" : "permissions.status", params: [:]))
    }
}

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apps", abstract: "List running applications.")

    @Flag(name: .customLong("all"), help: "Include background/agent apps, not just regular foreground apps.")
    var includeAll = false

    func run() throws {
        emit(DaemonClient.send(command: "apps.list", params: ["all": includeAll]))
    }
}

struct DisplaysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "displays",
        abstract: "List connected displays and their global-coordinate bounds.",
        discussion: """
        Every "frame" this tool prints (windows, elements, screenshots) is in \
        global-Quartz coordinates, anchored to the *primary* display's \
        top-left corner — so a display positioned left of or above the \
        primary one in System Settings > Displays has negative x/y in its \
        bounds. Use this command to see that topology before reasoning about \
        coordinates on a non-primary display. The "index" field matches the \
        index `screenshot --screen <index>` expects.
        """
    )

    func run() throws {
        emit(DaemonClient.send(command: "displays.list", params: [:]))
    }
}

struct WindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "windows", abstract: "List on-screen windows, optionally filtered to one app.")

    @Option(help: "Filter to windows owned by this app (name substring, bundle id, or pid).")
    var app: String?

    func run() throws {
        var params: JSONDict = [:]
        if let app { params["app"] = app }
        emit(DaemonClient.send(command: "windows.list", params: params))
    }
}

struct ActivateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "activate", abstract: "Bring an application (and optionally a specific window) to the front.")

    @Option(help: "App to activate (name substring, bundle id, or pid).")
    var app: String

    @Option(help: "Also raise this specific window id (from `windows`).")
    var window: Int?

    func run() throws {
        var params: JSONDict = ["app": app]
        if let window { params["window"] = window }
        emit(DaemonClient.send(command: "activate", params: params))
    }
}
