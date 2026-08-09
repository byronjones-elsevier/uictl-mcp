import ArgumentParser

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP server over stdio, exposing every capability as an MCP tool (add via `claude mcp add uictl -- uictl mcp`)."
    )

    // Kept as a plain ParsableCommand (not AsyncParsableCommand) and bridged
    // via runSync: a concrete type conforming to both ParsableCommand and
    // AsyncParsableCommand ends up with two same-named `run()` witnesses (the
    // sync default and the real async one), and calling `.run()` — even on
    // the concrete type — silently resolves to the sync default instead of
    // running the server. Confirmed by hand: with AsyncParsableCommand, `uictl
    // mcp` printed its help text instead of starting the stdio server.
    func run() throws {
        try runSync { try await MCPServer.run() }
    }
}
