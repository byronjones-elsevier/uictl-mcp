import ArgumentParser

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Pin uictl to one window so click/move/scroll/type/key re-focus it automatically first.",
        discussion: """
        Once held, every click/move/scroll/type/key call checks whether the \
        held window's app is frontmost and, if not, re-activates and raises \
        it before acting — countering a human's own mouse/keyboard use (e.g. \
        clicking into the terminal running uictl) stealing focus away from \
        whatever uictl is mid-task automating. Release the hold when done so \
        later commands stop being redirected.
        """,
        subcommands: [Hold.self, Release.self, Status.self]
    )

    struct Hold: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start holding focus on a window.")

        @Option(help: "Window id (from `windows`) to hold.")
        var window: Int?

        @Option(help: "App whose frontmost window to hold (name substring, bundle id, or pid).")
        var app: String?

        func run() throws {
            var params: JSONDict = [:]
            if let window { params["window"] = window }
            if let app { params["app"] = app }
            emit(DaemonClient.send(command: "focus.hold", params: params))
        }
    }

    struct Release: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop holding focus.")

        func run() throws {
            emit(DaemonClient.send(command: "focus.release", params: [:]))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show what window (if any) is currently held.")

        func run() throws {
            emit(DaemonClient.send(command: "focus.status", params: [:]))
        }
    }
}
