import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the background uictl daemon that holds Accessibility/Screen-Recording permissions and element-id state.",
        subcommands: [Start.self, Stop.self, Status.self],
        defaultSubcommand: Status.self
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the daemon (auto-invoked by any other command if it isn't already running).")

        @Flag(help: "Run in the foreground instead of spawning a detached background process. Used internally by other commands to bootstrap the daemon.")
        var foreground = false

        func run() throws {
            if foreground {
                try DaemonServer().run(foreground: true)
                return
            }
            try DaemonClient.ensureRunning()
            emit(successResponse(["started": true, "socket": UICtlPaths.socketPath]))
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the running daemon.")

        func run() throws {
            if !DaemonClient.isRunning() {
                emit(successResponse(["stopped": false, "reason": "not running"]))
            }
            let response = DaemonClient.send(command: "shutdown", params: [:])
            emit(response)
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Report whether the daemon is running.")

        func run() throws {
            let running = DaemonClient.isRunning()
            var pid: Int?
            if running, let pidText = try? String(contentsOfFile: UICtlPaths.pidFilePath, encoding: .utf8) {
                pid = Int(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let pidValue: Any = pid ?? NSNull()
            emit(successResponse(["running": running, "pid": pidValue, "socket": UICtlPaths.socketPath]))
        }
    }
}
