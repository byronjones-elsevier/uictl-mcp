import ArgumentParser

struct Root: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uictl",
        abstract: "Find, inspect, and drive running macOS GUI apps from the command line or from an MCP client.",
        discussion: """
        uictl locates running applications, lists and activates their windows, \
        screenshots them (optionally with a numbered element overlay), walks their \
        accessibility tree, clicks, types, sends key combos, waits for elements to \
        appear, runs OCR, samples pixel colors, and reads/writes the clipboard.

        A small daemon (auto-started on first use) holds Accessibility/Screen \
        Recording permission grants and the element-id cache across invocations — \
        see `uictl daemon status`.

        Every command prints one JSON object to stdout and exits 0 on success, \
        non-zero on failure.
        """,
        version: "0.1.0",
        subcommands: [
            DaemonCommand.self,
            PermissionsCommand.self,
            AppsCommand.self,
            DisplaysCommand.self,
            WindowsCommand.self,
            ActivateCommand.self,
            ScreenshotCommand.self,
            ElementsCommand.self,
            ClickCommand.self,
            MoveCommand.self,
            ScrollCommand.self,
            TypeCommand.self,
            KeyCommand.self,
            WaitForCommand.self,
            OCRCommand.self,
            PixelCommand.self,
            ClipboardCommand.self,
            LogCommand.self,
            MCPCommand.self,
        ]
    )
}
