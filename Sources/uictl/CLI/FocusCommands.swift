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
        whatever uictl is mid-task automating. Each of those commands' \
        response then includes a "focusHold" field: "alreadyFrontmost" if \
        nothing needed to change, "reactivated" if it did and the held \
        window is now frontmost, or "failed" if the attempt didn't stick — \
        don't assume the action landed on the intended window when it's \
        "failed". The first `hold` in a hold/[hold...]/release sequence \
        also snapshots whatever was frontmost right before it — typically \
        the terminal/IDE this agent is running in — so `release` can put \
        focus back there automatically instead of leaving it on the \
        automation target.
        """,
        subcommands: [Hold.self, Release.self, Status.self]
    )

    struct Hold: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start holding focus on a window.",
            discussion: """
            If nothing is currently held, also snapshots whatever's \
            frontmost right now so a later `release` can restore it. \
            Re-targeting to a different window while already holding one \
            (calling `hold` again without an intervening `release`) leaves \
            that original snapshot alone.
            """
        )

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
        static let configuration = CommandConfiguration(
            abstract: "Stop holding focus.",
            discussion: """
            Also restores focus to whatever was frontmost right before the \
            first `hold` in this sequence, if that could be captured — the \
            response's "restoredFocus" field reports the outcome \
            ("alreadyFrontmost"/"reactivated"/"failed"), omitted entirely \
            if there was nothing to restore.
            """
        )

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
