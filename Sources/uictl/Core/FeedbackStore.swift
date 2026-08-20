import Foundation

enum FeedbackCategory: String, Codable {
    case issue, error, recommendation
}

enum FeedbackStatus: String, Codable {
    case draft, submitted
}

struct FeedbackEntry: Codable {
    let id: Int
    var category: FeedbackCategory
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var status: FeedbackStatus
    var submittedAt: Date?
    var submittedUrl: String?
}

/// Local-first storage for feedback (issues/errors/recommendations) about
/// uictl itself, before a separate `submit` step hands a specific entry off
/// to GitHub. One JSON file (`~/.uictl/feedback.json`), read-modify-written
/// on every call — feedback CRUD isn't a hot path the way `ActivityLog` is,
/// so there's no in-memory cache to keep coherent, just a serial queue
/// guarding against two daemon requests racing on the file.
enum FeedbackStore {
    private static let queue = DispatchQueue(label: "uictl.feedbackstore")

    private struct FileContents: Codable {
        var nextId: Int
        var entries: [FeedbackEntry]
    }

    static func create(category: FeedbackCategory, title: String, body: String) throws -> FeedbackEntry {
        try queue.sync {
            var contents = try load()
            let now = Date()
            let entry = FeedbackEntry(
                id: contents.nextId, category: category, title: title, body: body,
                createdAt: now, updatedAt: now, status: .draft, submittedAt: nil, submittedUrl: nil
            )
            contents.entries.append(entry)
            contents.nextId += 1
            try save(contents)
            return entry
        }
    }

    static func list() throws -> [FeedbackEntry] {
        try queue.sync { try load().entries }
    }

    static func get(id: Int) throws -> FeedbackEntry {
        try queue.sync { try find(id: id, in: try load()) }
    }

    static func update(id: Int, category: FeedbackCategory?, title: String?, body: String?) throws -> FeedbackEntry {
        try queue.sync {
            var contents = try load()
            let index = try indexOf(id: id, in: contents)
            if let category { contents.entries[index].category = category }
            if let title { contents.entries[index].title = title }
            if let body { contents.entries[index].body = body }
            contents.entries[index].updatedAt = Date()
            try save(contents)
            return contents.entries[index]
        }
    }

    static func delete(id: Int) throws {
        try queue.sync {
            var contents = try load()
            let index = try indexOf(id: id, in: contents)
            contents.entries.remove(at: index)
            try save(contents)
        }
    }

    /// Marks an entry submitted without opening anything — used once a URL
    /// has already been handed to (and presumably opened by) an MCP client
    /// via URL-mode elicitation, so the daemon doesn't also open its own
    /// browser tab for the same submission.
    static func markSubmitted(id: Int, url: String) throws -> FeedbackEntry {
        try queue.sync {
            var contents = try load()
            let index = try indexOf(id: id, in: contents)
            contents.entries[index].status = .submitted
            contents.entries[index].submittedAt = Date()
            contents.entries[index].submittedUrl = url
            try save(contents)
            return contents.entries[index]
        }
    }

    /// GitHub natively pre-fills a new issue's title/body from query params.
    /// The category has no matching field there, so it's folded into the body.
    static func submissionURL(for entry: FeedbackEntry, repo: String) throws -> URL {
        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: entry.title),
            URLQueryItem(name: "body", value: "**Category:** \(entry.category.rawValue)\n\n\(entry.body)"),
        ]
        guard let url = components?.url else {
            throw UICtlError.message("failed to build a submission URL for repo \"\(repo)\"")
        }
        return url
    }

    // MARK: - Lookup helpers

    private static func indexOf(id: Int, in contents: FileContents) throws -> Int {
        guard let index = contents.entries.firstIndex(where: { $0.id == id }) else {
            throw UICtlError.message("no feedback entry with id \(id)")
        }
        return index
    }

    private static func find(id: Int, in contents: FileContents) throws -> FeedbackEntry {
        contents.entries[try indexOf(id: id, in: contents)]
    }

    // MARK: - File I/O

    private static func load() throws -> FileContents {
        guard FileManager.default.fileExists(atPath: UICtlPaths.feedbackFilePath) else {
            return FileContents(nextId: 1, entries: [])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: UICtlPaths.feedbackFilePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FileContents.self, from: data)
    }

    private static func save(_ contents: FileContents) throws {
        try UICtlPaths.ensureHomeDir()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(contents)
        try data.write(to: URL(fileURLWithPath: UICtlPaths.feedbackFilePath))
    }
}

extension FeedbackEntry {
    var jsonDict: JSONDict {
        let formatter = ISO8601DateFormatter()
        var dict: JSONDict = [
            "id": id,
            "category": category.rawValue,
            "title": title,
            "body": body,
            "createdAt": formatter.string(from: createdAt),
            "updatedAt": formatter.string(from: updatedAt),
            "status": status.rawValue,
        ]
        dict["submittedAt"] = submittedAt.map { formatter.string(from: $0) } ?? NSNull()
        dict["submittedUrl"] = submittedUrl ?? NSNull()
        return dict
    }
}
