import ArgumentParser

struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Show or export the daemon's activity log of every CLI/MCP call it has handled.",
        subcommands: [Show.self, Export.self]
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the on-screen activity log window.")

        func run() throws {
            emit(DaemonClient.send(command: "log.show", params: [:]))
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export the activity log as JSON.")

        @Option(help: "Output JSON path. Defaults under ~/.uictl/exports/.")
        var out: String?

        func run() throws {
            var params: JSONDict = [:]
            if let out { params["out"] = out }
            emit(DaemonClient.send(command: "log.export", params: params))
        }
    }
}
