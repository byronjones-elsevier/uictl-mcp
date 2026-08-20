import ArgumentParser

struct FeedbackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "feedback",
        abstract: "Draft, review, and submit feedback (issues/errors/recommendations) about uictl itself.",
        discussion: """
        Feedback is stored locally first (~/.uictl/feedback.json) so it can be \
        drafted, listed, and edited before anything leaves this machine. \
        `submit` hands a specific entry off to GitHub by opening a pre-filled \
        "new issue" page — it does not create the issue itself; you still \
        need to review and click "Submit new issue" there.
        """,
        subcommands: [Create.self, List.self, Get.self, Update.self, Delete.self, CheckDuplicates.self, Submit.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Draft a new local feedback entry.")

        @Option(help: "One of: issue, error, recommendation.")
        var category: String

        @Option(help: "Short summary — becomes the GitHub issue title.")
        var title: String

        @Option(help: "Full description — becomes the GitHub issue body.")
        var body: String

        func run() throws {
            emit(DaemonClient.send(command: "feedback.create", params: ["category": category, "title": title, "body": body]))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all local feedback entries.")

        func run() throws {
            emit(DaemonClient.send(command: "feedback.list", params: [:]))
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one feedback entry in full.")

        @Argument(help: "Feedback entry id (from `feedback list`).")
        var id: Int

        func run() throws {
            emit(DaemonClient.send(command: "feedback.get", params: ["id": id]))
        }
    }

    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Edit a local feedback entry.")

        @Argument(help: "Feedback entry id (from `feedback list`).")
        var id: Int

        @Option(help: "One of: issue, error, recommendation.")
        var category: String?

        @Option(help: "New title.")
        var title: String?

        @Option(help: "New body.")
        var body: String?

        func run() throws {
            var params: JSONDict = ["id": id]
            if let category { params["category"] = category }
            if let title { params["title"] = title }
            if let body { params["body"] = body }
            emit(DaemonClient.send(command: "feedback.update", params: params))
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a local feedback entry.")

        @Argument(help: "Feedback entry id (from `feedback list`).")
        var id: Int

        func run() throws {
            emit(DaemonClient.send(command: "feedback.delete", params: ["id": id]))
        }
    }

    struct CheckDuplicates: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check-duplicates",
            abstract: "Check a local entry's title against existing GitHub issues, without submitting anything.",
            discussion: """
            Needs a GitHub token if the repo is private: pass --token, set \
            GITHUB_TOKEN, or have `gh` already authenticated — otherwise \
            this just reports that it couldn't check. `submit` runs this \
            same check automatically before opening anything.
            """
        )

        @Argument(help: "Feedback entry id (from `feedback list`).")
        var id: Int

        @Option(help: "GitHub repo to check against, as \"owner/repo\". Defaults to uictl's own repo.")
        var repo: String?

        @Option(help: "GitHub token, if the repo needs one. Falls back to $GITHUB_TOKEN, then `gh auth token`.")
        var token: String?

        func run() throws {
            var params: JSONDict = ["id": id]
            if let repo { params["repo"] = repo }
            if let token { params["token"] = token }
            emit(DaemonClient.send(command: "feedback.checkDuplicates", params: params))
        }
    }

    struct Submit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check for an existing duplicate, then open GitHub's new-issue page with this entry's title/body pre-filled.",
            discussion: """
            First checks this entry's title against existing GitHub issues \
            (see `check-duplicates` — needs a token for a private repo, and \
            gracefully skips the check rather than blocking if none is \
            available); if a likely duplicate is found, the local entry is \
            deleted and nothing is opened. Otherwise opens the URL directly \
            in your default browser — running this command is treated as \
            your confirmation. (The MCP tool uictl_feedback_submit instead \
            asks you to review it first via MCP elicitation, since an agent \
            may call it without you having typed anything yourself.)
            """
        )

        @Argument(help: "Feedback entry id (from `feedback list`).")
        var id: Int

        @Option(help: "GitHub repo to submit to, as \"owner/repo\". Defaults to uictl's own repo.")
        var repo: String?

        @Option(help: "GitHub token, for the duplicate check against a private repo. Falls back to $GITHUB_TOKEN, then `gh auth token`.")
        var token: String?

        func run() throws {
            var params: JSONDict = ["id": id]
            if let repo { params["repo"] = repo }
            if let token { params["token"] = token }
            emit(DaemonClient.send(command: "feedback.submit", params: params))
        }
    }
}
