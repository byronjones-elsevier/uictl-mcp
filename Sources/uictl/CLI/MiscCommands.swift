import ArgumentParser

struct WaitForCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait-for",
        abstract: "Block until an element matching --role/--title appears in a window, or --timeout elapses."
    )

    @Option(help: "Window id (from `windows`). Either this or --app is required.")
    var window: Int?

    @Option(help: "App whose frontmost window to watch.")
    var app: String?

    @Option(help: "AXRole to match (e.g. AXButton).")
    var role: String?

    @Option(help: "Title/description substring to match.")
    var title: String?

    @Option(help: "Seconds to wait before giving up.")
    var timeout: Double = 10

    func run() throws {
        var params: JSONDict = ["timeout": timeout]
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        if let role { params["role"] = role }
        if let title { params["title"] = title }
        emit(DaemonClient.send(command: "waitFor", params: params))
    }
}

struct ClipboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read or write the system clipboard.",
        subcommands: [Get.self, Set.self]
    )

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the current clipboard text.")
        func run() throws {
            emit(DaemonClient.send(command: "clipboard.get", params: [:]))
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the clipboard to the given text.")
        @Argument(help: "Text to place on the clipboard.")
        var text: String
        func run() throws {
            emit(DaemonClient.send(command: "clipboard.set", params: ["text": text]))
        }
    }
}
