import MCP
import Foundation

/// Implements `uictl_feedback_submit`'s elicitation flow. Lives outside
/// `MCPServer.swift`'s generic forward-to-the-daemon path because it needs
/// the live `Server` object (elicitation only exists between this MCP
/// session and its connected client — the daemon has no part in it).
enum FeedbackSubmission {
    /// How long to wait for the connected client to respond to an
    /// elicitation before giving up. The SDK itself has no timeout — an
    /// unsupported or unresponsive client would otherwise hang this tool
    /// call forever.
    private static let elicitationTimeout: Double = 120

    static func handle(server: Server, args: [String: Any]) async -> CallTool.Result {
        do {
            guard let id = args["id"] as? Int else {
                throw UICtlError.message("\"id\" is required")
            }
            let repo = (args["repo"] as? String) ?? "byronjones-elsevier/uictl-mcp"
            let token = args["token"] as? String

            let fetched = DaemonClient.send(command: "feedback.get", params: ["id": id])
            guard (fetched["ok"] as? Bool) == true, let entry = fetched["data"] as? JSONDict else {
                return errorResult(fetched["error"] as? String ?? "feedback entry \(id) not found")
            }
            var title = entry["title"] as? String ?? ""
            var body = entry["body"] as? String ?? ""

            var dupParams: JSONDict = ["id": id, "repo": repo]
            if let token { dupParams["token"] = token }
            // Check for an existing GitHub issue before bothering the human
            // with a review prompt at all — if this already exists there,
            // there's nothing to review, just discard the local draft.
            let dupResponse = DaemonClient.send(command: "feedback.checkDuplicates", params: dupParams)
            if let dupData = dupResponse["data"] as? JSONDict,
               let duplicates = dupData["duplicates"] as? [JSONDict], let matched = duplicates.first {
                _ = DaemonClient.send(command: "feedback.delete", params: ["id": id])
                return successResult(["submitted": false, "duplicate": true, "deletedLocally": true, "matchedIssue": matched])
            }

            // Step 1: form-mode elicitation — let the human review (and
            // tweak) the content before anything about it leaves this
            // machine, since it was an agent asking to send it, not them.
            let review: CreateElicitation.Result
            do {
                let originalTitle = title
                let originalBody = body
                review = try await withTimeout(seconds: elicitationTimeout) {
                    try await server.requestElicitation(
                        message: "An AI agent wants to submit this feedback to \(repo)'s GitHub Issues. Review it (edit either field if you like) before it's sent anywhere:",
                        requestedSchema: Elicitation.RequestSchema(
                            title: "Review feedback before submitting",
                            properties: [
                                "title": .object(["type": "string", "title": "Title", "default": .string(originalTitle)]),
                                "body": .object(["type": "string", "title": "Description", "default": .string(originalBody)]),
                            ],
                            required: ["title", "body"]
                        ),
                        mode: .form
                    )
                }
            } catch {
                // Client likely doesn't support elicitation (or timed out) —
                // fall back to the same non-interactive path the CLI uses,
                // rather than failing outright.
                return fallbackSubmit(id: id, repo: repo, token: token, reason: "\(error)")
            }

            guard review.action == .accept else {
                return successResult(["submitted": false, "reason": "review \(reviewOutcomeDescription(review.action))"])
            }
            if let editedTitle = review.content?["title"]?.stringValue, !editedTitle.isEmpty { title = editedTitle }
            if let editedBody = review.content?["body"]?.stringValue, !editedBody.isEmpty { body = editedBody }
            if title != (entry["title"] as? String) || body != (entry["body"] as? String) {
                _ = DaemonClient.send(command: "feedback.update", params: ["id": id, "title": title, "body": body])
            }

            let urlResponse = DaemonClient.send(command: "feedback.buildUrl", params: ["id": id, "repo": repo])
            guard (urlResponse["ok"] as? Bool) == true,
                  let urlData = urlResponse["data"] as? JSONDict,
                  let urlString = urlData["url"] as? String else {
                return errorResult(urlResponse["error"] as? String ?? "failed to build a submission URL")
            }

            // Step 2: URL-mode elicitation — hand the prepopulated page to
            // the client rather than the daemon silently opening a browser
            // tab on the agent's say-so.
            do {
                _ = try await withTimeout(seconds: elicitationTimeout) {
                    try await server.requestElicitation(message: "Opening GitHub with this feedback pre-filled — review and click \"Create\" there to finish.", url: urlString, elicitationId: UUID().uuidString)
                }
                let marked = DaemonClient.send(command: "feedback.markSubmitted", params: ["id": id, "url": urlString])
                return successResult(["submitted": true, "url": urlString, "entry": marked["data"] ?? NSNull()])
            } catch {
                return fallbackSubmit(id: id, repo: repo, token: token, reason: "\(error)")
            }
        } catch {
            return errorResult("\(error)")
        }
    }

    /// The client couldn't (or didn't) handle one of the elicitations —
    /// open the URL directly on this machine instead of failing outright,
    /// same as the CLI's `feedback submit`. This still gets the feedback
    /// as far as a human's browser; it just skips the review round trip.
    /// (`feedback.submit` re-runs its own duplicate check regardless, so
    /// this can still legitimately come back as "deleted as a duplicate"
    /// rather than "submitted" — don't override whatever it reports.)
    private static func fallbackSubmit(id: Int, repo: String, token: String?, reason: String) -> CallTool.Result {
        var params: JSONDict = ["id": id, "repo": repo]
        if let token { params["token"] = token }
        let submitted = DaemonClient.send(command: "feedback.submit", params: params)
        guard (submitted["ok"] as? Bool) == true, let data = submitted["data"] as? JSONDict else {
            return errorResult(submitted["error"] as? String ?? reason)
        }
        var result = data
        if result["submitted"] == nil { result["submitted"] = true }
        result["elicitationFallback"] = reason
        return successResult(result)
    }

    private static func successResult(_ data: JSONDict) -> CallTool.Result {
        .init(content: [.text(text: jsonString(successResponse(data)), annotations: nil, _meta: nil)], isError: false)
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: jsonString(errorResponse(message)), annotations: nil, _meta: nil)], isError: true)
    }

    /// `action.rawValue` + "d" reads fine for "declined" but produces
    /// "canceld" for `.cancel` — spell each outcome out properly instead.
    private static func reviewOutcomeDescription(_ action: CreateElicitation.Result.Action) -> String {
        switch action {
        case .accept: return "accepted"
        case .decline: return "declined"
        case .cancel: return "cancelled"
        }
    }
}

private struct TimeoutError: Error, CustomStringConvertible {
    var description: String { "timed out waiting for the client's response" }
}

/// Guards a `CheckedContinuation` against being resumed twice — whichever of
/// the two independent tasks below (`operation`, or the timeout) gets here
/// first wins; the other's result, if it ever arrives, is just discarded.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let alreadyResumed = resumed
        resumed = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(with: result)
    }
}

/// `withThrowingTaskGroup`-based racing turned out not to work here: a
/// timeout child task correctly fires and throws (confirmed via logging),
/// but `group.next()` never returns while the other child (an elicitation
/// response that's never coming) is still outstanding — root cause not
/// isolated, plausibly something about how the vendored SDK's continuation-
/// based `sendAndAwait` interacts with task-group child cancellation/join.
/// This works around it: two fully independent, unjoined `Task`s race to
/// resume a single guarded continuation, so the loser can be silently
/// abandoned forever without this function ever needing to wait on it.
private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = ResumeOnce(continuation)

        let operationTask = Task {
            do {
                once.resume(with: .success(try await operation()))
            } catch {
                once.resume(with: .failure(error))
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(with: .failure(TimeoutError()))
            // Best-effort: the SDK's continuation-based wait may not check
            // for cancellation, but asking costs nothing, and it's the
            // difference between "leaked for the life of the process" and
            // "cleaned up" for any operation that does.
            operationTask.cancel()
        }
    }
}
