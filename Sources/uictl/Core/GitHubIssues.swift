import Foundation

struct GitHubIssueSummary {
    let number: Int
    let title: String
    let url: String
    let state: String
}

enum GitHubIssuesError: Error, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

/// Fetches a repo's issues from the public GitHub REST API, to check a
/// draft feedback entry against before submitting it. Unauthenticated
/// requests work fine against public repos (just a much lower rate limit);
/// a private repo needs `token` — see `GitHubToken`. Every failure mode
/// (missing token, rate limit, network error) surfaces as
/// `GitHubIssuesError.unavailable` so callers can treat "couldn't check" as
/// "skip the check" rather than blocking submission on it.
enum GitHubIssues {
    static func fetchAll(repo: String, token: String?) throws -> [GitHubIssueSummary] {
        try runSync {
            var allIssues: [GitHubIssueSummary] = []
            var page = 1
            // A generous but finite cap — this is a duplicate-title scan,
            // not a full mirror; 1000 issues is far more than that needs.
            while page <= 10 {
                guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/issues") else {
                    throw GitHubIssuesError.unavailable("invalid repo \"\(repo)\"")
                }
                components.queryItems = [
                    URLQueryItem(name: "state", value: "all"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: "\(page)"),
                ]
                guard let url = components.url else {
                    throw GitHubIssuesError.unavailable("invalid repo \"\(repo)\"")
                }

                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("uictl", forHTTPHeaderField: "User-Agent")
                if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await URLSession.shared.data(for: request)
                } catch {
                    throw GitHubIssuesError.unavailable("network error contacting GitHub: \(error.localizedDescription)")
                }
                guard let http = response as? HTTPURLResponse else {
                    throw GitHubIssuesError.unavailable("unexpected response from GitHub")
                }
                guard http.statusCode == 200 else {
                    let hint = token == nil
                        ? "this repo may be private — set GITHUB_TOKEN, authenticate `gh`, or pass --token"
                        : "check that the token has access to this repo"
                    throw GitHubIssuesError.unavailable("GitHub returned HTTP \(http.statusCode) for \(repo) (\(hint))")
                }
                guard let raw = try? JSONSerialization.jsonObject(with: data) as? [JSONDict] else {
                    throw GitHubIssuesError.unavailable("failed to parse GitHub's response")
                }
                if raw.isEmpty { break }

                for item in raw {
                    // The issues endpoint also returns pull requests.
                    guard item["pull_request"] == nil,
                          let number = item["number"] as? Int,
                          let title = item["title"] as? String,
                          let htmlURL = item["html_url"] as? String,
                          let state = item["state"] as? String else { continue }
                    allIssues.append(GitHubIssueSummary(number: number, title: title, url: htmlURL, state: state))
                }
                if raw.count < 100 { break }
                page += 1
            }
            return allIssues
        }
    }

    /// A deliberately simple, transparent heuristic — case-insensitive
    /// equality or substring containment either direction — meant to catch
    /// obvious re-reports, not near-miss wording. Not fuzzy matching.
    static func findDuplicates(title: String, in issues: [GitHubIssueSummary]) -> [GitHubIssueSummary] {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return issues.filter { issue in
            let other = issue.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return other == normalized || other.contains(normalized) || normalized.contains(other)
        }
    }
}
